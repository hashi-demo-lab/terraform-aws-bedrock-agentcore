###############################################################################
# examples/complete/main.tf
#
# End-to-end demonstration of the bedrock-agentcore module with every
# optional feature enabled:
#
#   - Bring-your-own (BYO) consumer-managed KMS CMK
#   - Knowledge base backed by an OpenSearch Serverless vector collection
#     pointed at a consumer-owned S3 bucket created in this example
#   - One Lambda-backed action group with bedrock invoke permission and a
#     function-schema definition
#   - HTTP API Gateway front door with an attached JWT authorizer (the
#     consumer's responsibility per the module's documented contract)
#   - Configurable throttling and CORS
#
# Two-phase apply caveat
# ----------------------
# The opensearch-project/opensearch provider must be configured with the
# AOSS collection endpoint, which does not exist on the first apply. There
# are two supported patterns:
#
#   1. Two-phase apply (recommended for first-time provisioning):
#
#         terraform apply -target=module.agent.aws_opensearchserverless_collection.kb
#         terraform apply
#
#      The first command creates the collection and surfaces its endpoint;
#      the second command then completes the apply with the opensearch
#      provider properly configured.
#
#   2. Disable the KB on the first apply (`enable_knowledge_base = false`),
#      then flip it on for the second apply once the rest of the
#      infrastructure is stable.
#
# Per constitution §2.1, provider blocks live in EXAMPLES, not in the root
# module. The aws + opensearch + archive providers are all the consumer's
# responsibility to configure here.
###############################################################################

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = ">= 2.3"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# The opensearch provider must point at the AOSS collection endpoint. The
# endpoint is only known after aws_opensearchserverless_collection.kb has
# been created — hence the two-phase apply caveat documented above. AOSS
# data-plane SigV4 auth is implicit (`sign_aws_requests = true`).
#
# We construct the endpoint URL from the collection ARN. AOSS endpoints
# follow the pattern `https://<collection_id>.<region>.aoss.amazonaws.com`.
# The collection ARN is `arn:aws:aoss:<region>:<account>:collection/<id>`,
# so we split on `/` to extract the trailing id.
locals {
  aoss_collection_arn = try(module.agent.opensearch_collection_arn, "")
  aoss_collection_id  = local.aoss_collection_arn == "" ? "" : element(split("/", local.aoss_collection_arn), length(split("/", local.aoss_collection_arn)) - 1)
  aoss_endpoint       = local.aoss_collection_id == "" ? "https://placeholder.us-east-1.aoss.amazonaws.com" : "https://${local.aoss_collection_id}.us-east-1.aoss.amazonaws.com"
}

provider "opensearch" {
  url               = local.aoss_endpoint
  aws_region        = "us-east-1"
  healthcheck       = false
  sign_aws_requests = true
}

###############################################################################
# Caller identity (used in IAM policy conditions below)
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Consumer-managed (BYO) KMS CMK — passed into the module via kms_key_arn.
# Key policy must allow:
#   - root account (full KMS admin)
#   - bedrock.amazonaws.com (agent at-rest encryption)
#   - logs.<region>.amazonaws.com (CloudWatch log group encryption)
#   - aoss.amazonaws.com (OpenSearch Serverless collection at-rest encryption)
###############################################################################

data "aws_iam_policy_document" "byo_kms_key" {
  statement {
    sid       = "EnableRootAccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowBedrockAgentAndLogsAndAoss"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "bedrock.amazonaws.com",
        "logs.${data.aws_region.current.region}.amazonaws.com",
        "aoss.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key" "byo" {
  description             = "BYO CMK for bedrock-agentcore complete-example agent"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.byo_kms_key.json

  tags = {
    Name        = "complete-demo-byo"
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}

resource "aws_kms_alias" "byo" {
  name          = "alias/complete-demo-byo"
  target_key_id = aws_kms_key.byo.key_id
}

###############################################################################
# Consumer-owned S3 bucket for knowledge base source documents.
# Module never creates this bucket — the consumer brings it.
# Secure defaults: versioning, public access blocked, SSE with the BYO CMK,
# bucket policy denying non-TLS and granting bedrock.amazonaws.com read.
###############################################################################

resource "aws_s3_bucket" "kb" {
  bucket_prefix = "complete-demo-kb-"
  force_destroy = true

  tags = {
    Name        = "complete-demo-kb"
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "kb" {
  bucket = aws_s3_bucket.kb.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "kb" {
  bucket = aws_s3_bucket.kb.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kb" {
  bucket = aws_s3_bucket.kb.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.byo.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "kb_bucket" {
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.kb.arn,
      "${aws_s3_bucket.kb.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowBedrockKBRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.kb.arn,
      "${aws_s3_bucket.kb.arn}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "kb" {
  bucket = aws_s3_bucket.kb.id
  policy = data.aws_iam_policy_document.kb_bucket.json
}

###############################################################################
# Consumer Lambda function used as a Bedrock action group target.
# - Execution role allows CloudWatch Logs writes (no managed policy)
# - Resource-based policy allows bedrock.amazonaws.com:InvokeFunction scoped
#   to the agent ARN (the MODULE creates the equivalent permission too —
#   the explicit one here demonstrates the consumer-side stub for any
#   additional out-of-band Bedrock invocations).
###############################################################################

data "aws_iam_policy_document" "action_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "action_lambda" {
  name               = "complete-demo-action-lambda"
  assume_role_policy = data.aws_iam_policy_document.action_lambda_assume.json
}

data "aws_iam_policy_document" "action_lambda_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/complete-demo-action-lambda:*"]
  }
}

resource "aws_iam_role_policy" "action_lambda_logs" {
  name   = "logs"
  role   = aws_iam_role.action_lambda.id
  policy = data.aws_iam_policy_document.action_lambda_logs.json
}

resource "aws_cloudwatch_log_group" "action_lambda" {
  name              = "/aws/lambda/complete-demo-action-lambda"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.byo.arn
}

data "archive_file" "action_lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/action_lambda.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      def handler(event, _context):
          # Echo back a stub response in the Bedrock action-group function
          # response envelope. Replace with real business logic.
          return {
              "messageVersion": "1.0",
              "response": {
                  "actionGroup": event.get("actionGroup", "lookup"),
                  "function": event.get("function", "get_account_info"),
                  "functionResponse": {
                      "responseBody": {
                          "TEXT": {
                              "body": "stub response from action lambda"
                          }
                      }
                  }
              }
          }
    PY
  }
}

resource "aws_lambda_function" "action" {
  function_name    = "complete-demo-action-lambda"
  role             = aws_iam_role.action_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.action_lambda_zip.output_path
  source_code_hash = data.archive_file.action_lambda_zip.output_base64sha256

  kms_key_arn = aws_kms_key.byo.arn

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.action_lambda]
}

# Consumer-side bedrock invoke permission. The module ALSO emits an
# aws_lambda_permission for each action group, but this stub demonstrates
# the pattern when the consumer wires additional invocation paths (e.g.,
# a second agent in a different module) to the same function.
resource "aws_lambda_permission" "bedrock_invoke_action" {
  statement_id  = "AllowBedrockInvokeFromConsumer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.action.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = module.agent.agent_arn
}

###############################################################################
# Module invocation — every optional feature enabled
###############################################################################

module "agent" {
  source = "../.."

  agent_name  = "complete-demo"
  instruction = "You are a customer-service assistant for ACME Corp. Use the knowledge base to answer policy questions, the lookup action group for account-specific data, and the code interpreter for any calculations. Decline to answer questions outside ACME's product line."

  # Optional runtime tuning
  foundation_model         = "anthropic.claude-sonnet-4-20250514"
  agent_alias_name         = "live"
  idle_session_ttl_seconds = 1800

  # Code interpreter: AWS-managed action group
  enable_code_interpreter = true

  # Lambda action group — function schema (no OpenAPI required)
  action_group_definitions = {
    lookup = {
      description = "Look up customer account information by account ID."
      lambda_arn  = aws_lambda_function.action.arn
      function_schema = {
        functions = [
          {
            name        = "get_account_info"
            description = "Return account metadata for the given account ID."
            parameters = {
              account_id = {
                type        = "string"
                description = "Numeric account identifier"
                required    = true
              }
            }
          }
        ]
      }
    }
  }

  # Knowledge base
  enable_knowledge_base             = true
  knowledge_base_s3_bucket_arn      = aws_s3_bucket.kb.arn
  knowledge_base_s3_kms_key_arn     = aws_kms_key.byo.arn
  knowledge_base_inclusion_prefixes = ["docs/"]
  knowledge_base_embedding_model_id = "amazon.titan-embed-text-v2:0"
  knowledge_base_description        = "ACME Corp customer-service knowledge corpus including policy documents, FAQs, and pricing sheets."

  # API Gateway HTTP front door
  enable_api_gateway         = true
  api_throttling_rate_limit  = 100
  api_throttling_burst_limit = 200
  cors_configuration = {
    allow_origins = ["https://app.example.com"]
    allow_methods = ["POST"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 600
  }

  # Guardrail — fill in your guardrail identifier (lowercase alphanumerics)
  # before applying. Leaving as "" disables the binding.
  guardrail_id      = ""
  guardrail_version = "DRAFT"

  # BYO encryption + log retention
  kms_key_arn        = aws_kms_key.byo.arn
  log_retention_days = 365

  # Tags
  environment = "sandbox"
  owner       = "platform-team@example.com"
  cost_center = "CC-1234"
  project     = "agent-poc"

  tags = {
    Application = "complete-demo"
  }

  depends_on = [aws_kms_alias.byo]
}

###############################################################################
# Consumer-attached JWT authorizer on the module's HTTP API.
#
# The module exposes the API id, the default route key (POST /invoke), and
# the integration target as outputs; the consumer attaches the authorizer
# and overrides the route's authorization_type from "NONE" to "JWT" by
# managing the route itself (terraform import or a separate config). For
# brevity in this example we attach a standalone authorizer resource and
# document the route override that the consumer must apply.
###############################################################################

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = module.agent.api_id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "complete-demo-jwt"

  jwt_configuration {
    audience = ["complete-demo-audience"]
    issuer   = "https://example.auth0.com/"
  }
}

###############################################################################
# Outputs — surface everything the operator needs to drive the demo
###############################################################################

output "agent_id" {
  description = "Bedrock agent identifier"
  value       = module.agent.agent_id
}

output "agent_arn" {
  description = "Bedrock agent ARN"
  value       = module.agent.agent_arn
}

output "agent_alias_arn" {
  description = "Invocation target for bedrock-agent-runtime:InvokeAgent"
  value       = module.agent.agent_alias_arn
}

output "agent_role_arn" {
  description = "ARN of the agent execution role"
  value       = module.agent.agent_role_arn
}

output "kms_key_arn" {
  description = "ARN of the consumer-managed (BYO) KMS CMK passed into the module"
  value       = module.agent.kms_key_arn
}

output "log_group_name" {
  description = "Agent CloudWatch log group name"
  value       = module.agent.log_group_name
}

output "knowledge_base_id" {
  description = "Knowledge base identifier"
  value       = module.agent.knowledge_base_id
}

output "knowledge_base_arn" {
  description = "Knowledge base ARN"
  value       = module.agent.knowledge_base_arn
}

output "data_source_id" {
  description = "S3 data source identifier — pass to bedrock-agent:StartIngestionJob"
  value       = module.agent.data_source_id
}

output "opensearch_collection_arn" {
  description = "AOSS vector collection ARN"
  value       = module.agent.opensearch_collection_arn
}

output "kb_bucket_name" {
  description = "Name of the consumer-owned KB source bucket"
  value       = aws_s3_bucket.kb.bucket
}

output "api_endpoint" {
  description = "HTTP API invoke URL (POST /invoke)"
  value       = module.agent.api_endpoint
}

output "api_id" {
  description = "HTTP API identifier"
  value       = module.agent.api_id
}

output "default_route_key" {
  description = "Route key on the module's HTTP API; the consumer overrides authorization_type to JWT and references the authorizer above"
  value       = module.agent.default_route_key
}

output "jwt_authorizer_id" {
  description = "Identifier of the consumer-attached JWT authorizer; bind to the route via terraform import or a separate aws_apigatewayv2_route resource"
  value       = aws_apigatewayv2_authorizer.jwt.id
}

output "invoker_lambda_arn" {
  description = "ARN of the bundled invoker Lambda fronting the agent"
  value       = module.agent.invoker_lambda_arn
}
