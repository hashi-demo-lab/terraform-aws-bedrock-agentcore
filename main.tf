###############################################################################
# main.tf — section placeholders. Resources land in Items B-F.
#
# This module follows the standard root-module structure:
#   - versions.tf   : Terraform + provider version constraints
#   - variables.tf  : Input variable declarations
#   - data.tf       : Account / partition / region context
#   - locals.tf     : Required tags, derived ARNs, conditional flags
#   - main.tf       : Resources (this file)
#   - outputs.tf    : Output value declarations
#
# Resources are organised by checklist item below to keep the eventual diff
# review and ownership lines obvious.
###############################################################################

# -----------------------------------------------------------------------------
# KMS encryption key + alias  (Item B)
# -----------------------------------------------------------------------------
# Module creates a customer-managed CMK only when the caller did NOT bring
# their own (var.kms_key_arn == ""). Both at-rest encryption paths (the agent
# resource and the agent log group) always use a CMK — there is no opt-out.
resource "aws_kms_key" "this" {
  count = local.create_kms ? 1 : 0

  description             = "CMK for Bedrock agent ${var.agent_name} and its CloudWatch log group."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms[0].json

  tags = local.tags
}

resource "aws_kms_alias" "this" {
  count = local.create_kms ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.this[0].key_id
}

# -----------------------------------------------------------------------------
# CloudWatch log group for the agent  (Item B)
# -----------------------------------------------------------------------------
# Always created (no opt-out). KMS encryption is mandatory and points at the
# resolved CMK ARN (BYO or module-managed).
resource "aws_cloudwatch_log_group" "agent" {
  name              = local.agent_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn_resolved

  tags = local.tags
}

# -----------------------------------------------------------------------------
# IAM execution role for the Bedrock agent  (Item B)
# -----------------------------------------------------------------------------
# Trust policy uses bedrock.amazonaws.com with aws:SourceAccount + aws:SourceArn
# confused-deputy guards built in data.aws_iam_policy_document.agent_assume.
# Inline policy is least-privilege and dynamically composed; see agent_inline.
resource "aws_iam_role" "agent" {
  name               = local.agent_role_name
  assume_role_policy = data.aws_iam_policy_document.agent_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy" "agent" {
  name   = "${local.agent_role_name}-inline"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_inline.json
}

# -----------------------------------------------------------------------------
# Bedrock agent + alias + AWS-managed code interpreter action group  (Item C)
# -----------------------------------------------------------------------------
# aws_bedrockagent_agent.this                        — always
# aws_bedrockagent_agent_action_group.code_interpreter — count = var.enable_code_interpreter ? 1 : 0
# time_sleep.wait_after_prepare                      — always
# aws_bedrockagent_agent_alias.this                  — always
#
# prepare_agent is set to false on the agent itself; the action-group-level
# prepare_agent (default true) drives the PrepareAgent API call so all attached
# action groups land before the DRAFT is compiled. The alias then targets the
# computed agent_version after a short time_sleep that papers over a known
# eventual-consistency window between PrepareAgent reporting complete and the
# new agent_version being addressable from CreateAgentAlias.
#
# guardrail_configuration is the modern typed-nested attribute (list of object)
# in the AWS provider — it is set with a list literal, NOT a dynamic block.
# Same shape for routing_configuration on the alias.
resource "aws_bedrockagent_agent" "this" {
  agent_name                  = var.agent_name
  agent_resource_role_arn     = aws_iam_role.agent.arn
  foundation_model            = var.foundation_model
  instruction                 = var.instruction
  idle_session_ttl_in_seconds = var.idle_session_ttl_seconds
  customer_encryption_key_arn = local.kms_key_arn_resolved
  description                 = "Bedrock agent ${var.agent_name} (managed by Terraform)."
  prepare_agent               = false
  skip_resource_in_use_check  = var.force_destroy

  guardrail_configuration = var.guardrail_id == "" ? [] : [{
    guardrail_identifier = var.guardrail_id
    guardrail_version    = var.guardrail_version
  }]

  tags = local.tags

  depends_on = [
    aws_iam_role_policy.agent,
    aws_cloudwatch_log_group.agent,
  ]
}

resource "aws_bedrockagent_agent_action_group" "code_interpreter" {
  count = var.enable_code_interpreter ? 1 : 0

  agent_id                      = aws_bedrockagent_agent.this.agent_id
  agent_version                 = "DRAFT"
  action_group_name             = "CodeInterpreterAction"
  parent_action_group_signature = "AMAZON.CodeInterpreter"
  action_group_state            = "ENABLED"
  prepare_agent                 = true
  skip_resource_in_use_check    = var.force_destroy

  # description, api_schema, action_group_executor are deliberately omitted —
  # the AWS API rejects CreateAgentActionGroup when these fields accompany a
  # parent_action_group_signature value.
}

resource "time_sleep" "wait_after_prepare" {
  create_duration  = "${var.wait_after_prepare_seconds}s"
  destroy_duration = "0s"

  depends_on = [
    aws_bedrockagent_agent.this,
    aws_bedrockagent_agent_action_group.code_interpreter,
    aws_bedrockagent_agent_action_group.lambda,
    aws_bedrockagent_agent_knowledge_base_association.this,
  ]
}

resource "aws_bedrockagent_agent_alias" "this" {
  agent_id         = aws_bedrockagent_agent.this.agent_id
  agent_alias_name = var.agent_alias_name
  description      = "Stable invocation alias for Bedrock agent ${var.agent_name}."

  routing_configuration = [{
    agent_version          = aws_bedrockagent_agent.this.agent_version
    provisioned_throughput = null
  }]

  tags = local.tags

  depends_on = [time_sleep.wait_after_prepare]

  # Subsequent applies that touch the agent will bump agent_version; ignoring
  # routing_configuration prevents the alias from churning on every plan and
  # keeps the "stable invocation handle" promise. Re-targeting requires a
  # deliberate taint or replacement.
  lifecycle {
    ignore_changes = [routing_configuration]
  }
}

# -----------------------------------------------------------------------------
# Lambda-backed action groups + permissions  (Item D)
# -----------------------------------------------------------------------------
# Each entry in var.action_group_definitions produces:
#   - one aws_lambda_permission allowing bedrock.amazonaws.com to invoke the
#     target Lambda, scoped to THIS agent's ARN via source_arn (prevents
#     cross-agent invocation in shared-Lambda topologies) and to the caller's
#     account via source_account.
#   - one aws_bedrockagent_agent_action_group bound to the DRAFT version with
#     either api_schema (payload OR s3 sub-block, mutually exclusive) or
#     function_schema. The mutual-exclusion is enforced at the variable level
#     (see variables.tf validations) so the resource block can use simple
#     dynamic blocks driven by null/non-null detection.
#
# Schema note: action_group_executor, api_schema, function_schema, and the
# nested s3 / member_functions / functions / parameters sub-blocks are all
# block-typed (list or set nesting), NOT typed-nested attributes — they are
# written with block syntax (no `=`) and emitted via dynamic blocks here.
# Parameter names are carried via map_block_key on the (set-typed) parameters
# block, a legacy schema artefact.
#
# depends_on on the action group references the entire bedrock_invoke map
# rather than a per-key element. This is sufficient because Terraform tracks
# dependencies on the whole map and avoids the for_each / each.key cycle that
# arises when action groups try to depend on a permission keyed by their own
# each.key while the permission resource also uses for_each.

resource "aws_lambda_permission" "bedrock_invoke" {
  for_each = {
    for k, v in var.action_group_definitions : k => v
    if try(v.lambda_arn, null) != null
  }

  statement_id   = "AllowBedrockAgentInvoke-${each.key}"
  action         = "lambda:InvokeFunction"
  function_name  = each.value.lambda_arn
  principal      = "bedrock.amazonaws.com"
  source_arn     = aws_bedrockagent_agent.this.agent_arn
  source_account = local.account_id
}

resource "aws_bedrockagent_agent_action_group" "lambda" {
  for_each = var.action_group_definitions

  agent_id                   = aws_bedrockagent_agent.this.agent_id
  agent_version              = "DRAFT"
  action_group_name          = each.key
  description                = try(each.value.description, null)
  action_group_state         = try(each.value.state, "ENABLED")
  prepare_agent              = true
  skip_resource_in_use_check = var.force_destroy

  dynamic "action_group_executor" {
    for_each = try(each.value.lambda_arn, null) == null ? [] : [each.value.lambda_arn]
    content {
      lambda = action_group_executor.value
    }
  }

  dynamic "api_schema" {
    for_each = try(each.value.api_schema, null) == null ? [] : [each.value.api_schema]
    content {
      payload = try(api_schema.value.payload, null)

      dynamic "s3" {
        for_each = try(api_schema.value.s3, null) == null ? [] : [api_schema.value.s3]
        content {
          s3_bucket_name = s3.value.s3_bucket_name
          s3_object_key  = s3.value.s3_object_key
        }
      }
    }
  }

  dynamic "function_schema" {
    for_each = try(each.value.function_schema, null) == null ? [] : [each.value.function_schema]
    content {
      member_functions {
        dynamic "functions" {
          for_each = function_schema.value.functions
          content {
            name        = functions.value.name
            description = functions.value.description

            dynamic "parameters" {
              for_each = try(functions.value.parameters, null) == null ? {} : functions.value.parameters
              content {
                map_block_key = parameters.key
                type          = parameters.value.type
                description   = parameters.value.description
                required      = try(parameters.value.required, false)
              }
            }
          }
        }
      }
    }
  }

  depends_on = [aws_lambda_permission.bedrock_invoke]
}

# -----------------------------------------------------------------------------
# Knowledge base: AOSS collection + IAM + KB + data source + association  (Item E)
# -----------------------------------------------------------------------------
# aws_iam_role.kb                                          — count = var.enable_knowledge_base ? 1 : 0
# aws_iam_role_policy.kb                                   — count = var.enable_knowledge_base ? 1 : 0
# aws_opensearchserverless_security_policy.encryption      — count = var.enable_knowledge_base ? 1 : 0
# aws_opensearchserverless_security_policy.network         — count = var.enable_knowledge_base ? 1 : 0
# aws_opensearchserverless_collection.kb                   — count = var.enable_knowledge_base ? 1 : 0
# aws_opensearchserverless_access_policy.kb                — count = var.enable_knowledge_base ? 1 : 0
# time_sleep.wait_aoss_dap                                 — count = var.enable_knowledge_base ? 1 : 0
# opensearch_index.kb                                      — count = var.enable_knowledge_base ? 1 : 0
# aws_bedrockagent_knowledge_base.this                     — count = var.enable_knowledge_base ? 1 : 0
# aws_bedrockagent_data_source.this                        — count = var.enable_knowledge_base ? 1 : 0
# aws_bedrockagent_agent_knowledge_base_association.this   — count = var.enable_knowledge_base ? 1 : 0
#
# Schema notes (verified via `terraform providers schema -json`):
#   - knowledge_base_configuration, vector_knowledge_base_configuration,
#     embedding_model_configuration, bedrock_embedding_model_configuration,
#     storage_configuration, opensearch_serverless_configuration, field_mapping
#     are ALL list-typed nested blocks (nesting_mode = "list"). Written with
#     block syntax (no `=`), addressed in tests via `[0]`.
#   - data_source_configuration, s3_configuration, vector_ingestion_configuration,
#     chunking_configuration, fixed_size_chunking_configuration, and
#     server_side_encryption_configuration are list-typed blocks too.
#   - aws_bedrockagent_data_source.s3_configuration.inclusion_prefixes is
#     attribute-typed (set of strings) and is set with `=` on the inline list.
#
# Provider note (opensearch): The opensearch-project/opensearch provider must
# be configured by the CONSUMER with the AOSS collection endpoint and SigV4
# auth. The constitution forbids hard-coded provider blocks inside reusable
# modules — see examples/complete/main.tf for the pattern. The module relies on
# the inherited provider configuration at the calling root.

# IAM execution role for the KB. Trust policy is in data.aws_iam_policy_document.kb_assume.
resource "aws_iam_role" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name               = local.kb_role_name
  assume_role_policy = data.aws_iam_policy_document.kb_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name   = "${local.kb_role_name}-inline"
  role   = aws_iam_role.kb[0].id
  policy = data.aws_iam_policy_document.kb_inline[0].json
}

# AOSS encryption security policy — applies to the named collection. AWS-owned
# vs CMK is selected by aws_owned_key (true) or kms_key_arn. This module's
# default uses the resolved CMK so AOSS data inherits the same key as the agent
# log group / agent. The policy targets the collection by name pattern.
resource "aws_opensearchserverless_security_policy" "encryption" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/${local.kb_collection_name}"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = false
    KmsARN      = local.kms_key_arn_resolved
  })
}

# AOSS network security policy. Default: AllowFromPublic = true so the basic
# example works without VPC plumbing. The encryption policy + IAM data-access
# policy are the security boundary; for production, set up a VPC endpoint and
# flip AllowFromPublic to false (documented in design.md and README).
resource "aws_opensearchserverless_security_policy" "network" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-net"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/${local.kb_collection_name}"]
          ResourceType = "collection"
        },
        {
          Resource     = ["collection/${local.kb_collection_name}"]
          ResourceType = "dashboard"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_collection" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name = local.kb_collection_name
  type = "VECTORSEARCH"

  tags = local.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# AOSS data-access policy (data plane). Grants the KB execution role the full
# index lifecycle on the collection and read/write on every document in the
# index — Bedrock manages the index contents internally. Principal is the KB
# role ARN, NOT the caller.
resource "aws_opensearchserverless_access_policy" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-dap"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = ["collection/${local.kb_collection_name}"]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DescribeCollectionItems",
            "aoss:UpdateCollectionItems",
          ]
          ResourceType = "collection"
        },
        {
          Resource = ["index/${local.kb_collection_name}/*"]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:UpdateIndex",
            "aoss:WriteDocument",
            "aoss:DeleteIndex",
          ]
          ResourceType = "index"
        }
      ]
      Principal   = [aws_iam_role.kb[0].arn]
      Description = "Bedrock KB data access for ${var.agent_name}"
    }
  ])
}

# AOSS data-access-policy propagation is eventually consistent. Without this
# pause, opensearch_index.kb (which calls the AOSS data-plane API as the
# Terraform principal-of-record) and the KB resource (which validates index
# existence) sporadically fail with AccessDeniedException on first apply. 60s
# matches the empirical recovery window documented in research-bedrock-knowledge-base.md.
resource "time_sleep" "wait_aoss_dap" {
  count = var.enable_knowledge_base ? 1 : 0

  create_duration = "60s"

  depends_on = [
    aws_opensearchserverless_access_policy.kb,
    aws_opensearchserverless_collection.kb,
  ]
}

# Pre-create the k-NN vector index so aws_bedrockagent_knowledge_base.this can
# validate the field mapping at create time. Field names MUST match the
# field_mapping block on the KB resource exactly; both are sourced from the
# same locals so they cannot drift.
#
# The opensearch provider must be configured by the consumer with the AOSS
# collection endpoint (aws_opensearchserverless_collection.kb[0].collection_endpoint)
# and aws_region; SigV4 auth signs as the caller's principal which has
# data-plane access via the AOSS data-access policy above.
resource "opensearch_index" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name                           = local.kb_vector_index_name
  number_of_shards               = "2"
  number_of_replicas             = "0"
  index_knn                      = true
  index_knn_algo_param_ef_search = "512"

  mappings = jsonencode({
    properties = {
      (local.kb_vector_field) = {
        type      = "knn_vector"
        dimension = local.kb_embedding_dimensions
        method = {
          name       = "hnsw"
          engine     = "faiss"
          space_type = "l2"
          parameters = {
            ef_construction = 512
            m               = 16
          }
        }
      }
      (local.kb_text_field) = {
        type = "text"
      }
      (local.kb_metadata_field) = {
        type  = "text"
        index = false
      }
    }
  })

  force_destroy = true

  depends_on = [time_sleep.wait_aoss_dap]
}

# Knowledge base resource — wires embedding model + AOSS storage + IAM role.
resource "aws_bedrockagent_knowledge_base" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  name        = local.kb_collection_name
  role_arn    = aws_iam_role.kb[0].arn
  description = var.knowledge_base_description

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn

      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions = local.kb_embedding_dimensions
        }
      }
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"

    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb[0].arn
      vector_index_name = local.kb_vector_index_name

      field_mapping {
        vector_field   = local.kb_vector_field
        text_field     = local.kb_text_field
        metadata_field = local.kb_metadata_field
      }
    }
  }

  tags = local.tags

  depends_on = [
    opensearch_index.kb,
    aws_iam_role_policy.kb,
  ]
}

# S3 data source — chunking strategy default FIXED_SIZE 300/20% per AWS console
# default and research-bedrock-knowledge-base.md. data_deletion_policy = RETAIN
# so destroying the data source preserves embeddings (re-create points at the
# same data without re-ingestion cost).
resource "aws_bedrockagent_data_source" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  knowledge_base_id    = aws_bedrockagent_knowledge_base.this[0].id
  name                 = "${var.agent_name}-source"
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn         = var.knowledge_base_s3_bucket_arn
      inclusion_prefixes = length(var.knowledge_base_inclusion_prefixes) > 0 ? var.knowledge_base_inclusion_prefixes : null
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"

      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }

  server_side_encryption_configuration {
    kms_key_arn = local.kms_key_arn_resolved
  }
}

# Bind the KB to the agent's DRAFT version. Adding this resource forces a
# re-prepare of the agent (the alias's wait_after_prepare timer therefore also
# depends on this resource — see depends_on block on time_sleep.wait_after_prepare
# above).
resource "aws_bedrockagent_agent_knowledge_base_association" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  agent_id             = aws_bedrockagent_agent.this.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this[0].id
  description          = var.knowledge_base_description
  knowledge_base_state = "ENABLED"

  depends_on = [aws_bedrockagent_data_source.this]
}

# -----------------------------------------------------------------------------
# API Gateway HTTP front door + invoker Lambda  (Item F)
# -----------------------------------------------------------------------------
# Topology:
#   client -> aws_apigatewayv2_api (HTTP, $default stage with throttle + JSON
#             access logs) -> aws_apigatewayv2_route POST /invoke ->
#             aws_apigatewayv2_integration (AWS_PROXY, payload v2.0) ->
#             aws_lambda_function.invoker (Python 3.12, X-Ray Active) ->
#             bedrock-agent-runtime:InvokeAgent against the alias.
#
# All resources gated on count = var.enable_api_gateway ? 1 : 0.
#
# Authorization is intentionally NONE on the route — consumers attach their
# own JWT/Lambda/IAM authorizer using the api_id / default_route_key /
# api_execution_arn outputs (see design.md §2 + research-bedrock-api-gateway.md).
#
# Schema notes (verified via provider docs):
#   - aws_apigatewayv2_stage.default_route_settings is list-typed `[0]`.
#   - aws_apigatewayv2_stage.access_log_settings is list-typed `[0]`.
#   - aws_apigatewayv2_stage.route_settings (per-route override) is set-typed —
#     not used here, but design.md §5 calls out one() for downstream tests.
#   - aws_lambda_function.tracing_config + environment + vpc_config are all
#     list-typed `[0]`.

# Lambda execution role for the invoker. Trust policy is in
# data.aws_iam_policy_document.lambda_assume — standard lambda.amazonaws.com.
resource "aws_iam_role" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name               = "${var.agent_name}-invoker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name   = "${var.agent_name}-invoker-inline"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda_inline[0].json
}

# Dedicated invoker Lambda log group — KMS-encrypted with the resolved CMK
# and configurable retention. Created BEFORE the function so its ARN is
# resolvable for the inline policy and the function's implicit logging path.
resource "aws_cloudwatch_log_group" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name              = "/aws/lambda/${var.agent_name}-invoker"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn_resolved

  tags = local.tags
}

# Bundled invoker Lambda. Source is the zipped files/invoker/ directory; the
# source_code_hash drives in-place updates on .py changes. Environment is
# encrypted at rest with the same CMK as the agent + log groups (kms_key_arn).
# X-Ray Active tracing is mandatory per the security baseline.
resource "aws_lambda_function" "invoker" {
  count = var.enable_api_gateway ? 1 : 0

  function_name    = "${var.agent_name}-invoker"
  role             = aws_iam_role.lambda[0].arn
  filename         = data.archive_file.invoker_zip[0].output_path
  source_code_hash = data.archive_file.invoker_zip[0].output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = local.kms_key_arn_resolved

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      AGENT_ID       = aws_bedrockagent_agent.this.agent_id
      AGENT_ALIAS_ID = aws_bedrockagent_agent_alias.this.agent_alias_id
    }
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

# HTTP API (v2). Protocol HTTP, no built-in CORS, no built-in authorizer —
# consumers attach their own. CORS is opt-in via var.cors_configuration in a
# future iteration (variable already declared in variables.tf).
resource "aws_apigatewayv2_api" "this" {
  count = var.enable_api_gateway ? 1 : 0

  name          = "${var.agent_name}-api"
  protocol_type = "HTTP"
  description   = "HTTP API for Bedrock agent ${var.agent_name}."

  tags = local.tags
}

# AWS_PROXY integration -> invoker Lambda. payload_format_version = "2.0" is
# required for HTTP API + Lambda proxy; timeout is hard-capped at 30000ms by
# the HTTP API service quota.
resource "aws_apigatewayv2_integration" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.invoker[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

# Single default route. authorization_type defaults to NONE — the design
# explicitly defers auth attachment to the consumer.
resource "aws_apigatewayv2_route" "invoke" {
  count = var.enable_api_gateway ? 1 : 0

  api_id             = aws_apigatewayv2_api.this[0].id
  route_key          = "POST /invoke"
  target             = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
  authorization_type = "NONE"
}

# API Gateway access log group — separate from the Lambda log group so
# retention/encryption can be tuned independently. Same CMK + retention defaults.
resource "aws_cloudwatch_log_group" "apigw_access" {
  count = var.enable_api_gateway ? 1 : 0

  name              = "/aws/apigateway/${var.agent_name}-access"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn_resolved

  tags = local.tags
}

# $default stage with auto_deploy. default_route_settings carries the throttle
# limits (per-stage default applied to all routes); access_log_settings emits a
# structured JSON record per request to the dedicated log group above.
resource "aws_apigatewayv2_stage" "default" {
  count = var.enable_api_gateway ? 1 : 0

  api_id      = aws_apigatewayv2_api.this[0].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttling_rate_limit
    throttling_burst_limit = var.api_throttling_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_access[0].arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = local.tags
}

# Resource-policy permission allowing the API Gateway service principal to
# invoke the function. source_arn pinned to this API + any stage + any route.
resource "aws_lambda_permission" "apigw_invoke" {
  count = var.enable_api_gateway ? 1 : 0

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.invoker[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this[0].execution_arn}/*/*"
}
