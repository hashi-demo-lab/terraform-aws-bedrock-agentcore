###############################################################################
# Account / partition / region context used to build derived ARNs and IAM
# confused-deputy conditions throughout the module.
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

###############################################################################
# Invoker Lambda source bundle (Item F).
#
# Zips the bundled Python 3.12 invoker (files/invoker/index.py) for upload to
# Lambda. Only created when the API Gateway frontend is enabled — keeps the
# .zip out of the working directory for consumers who only want the agent
# itself. The output_base64sha256 attribute drives Lambda's source_code_hash
# so updates to the .py file trigger a function update on the next apply.
###############################################################################

data "archive_file" "invoker_zip" {
  count = var.enable_api_gateway ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/files/invoker"
  output_path = "${path.module}/files/invoker.zip"
}

###############################################################################
# Bedrock agent execution role — trust policy (assume-role).
#
# Grants sts:AssumeRole to the bedrock.amazonaws.com service principal, with
# both confused-deputy guards required by the AWS Bedrock service-role docs:
#   - aws:SourceAccount  pinned to the caller's account
#   - aws:SourceArn      ArnLike-pinned to any agent in the caller's region
#
# Reference: docs.aws.amazon.com/bedrock/latest/userguide/agents-permissions.html
###############################################################################

data "aws_iam_policy_document" "agent_assume" {
  statement {
    sid     = "BedrockAgentAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:agent/*"]
    }
  }
}

###############################################################################
# Bedrock agent execution role — inline policy (least-privilege).
#
# Statements emitted unconditionally:
#   - InvokeFoundationModel : bedrock:InvokeModel* on the FM ARN.
#   - WriteAgentLogs        : logs:CreateLogStream/PutLogEvents on the agent
#                             log group ARN with stream wildcard.
#   - UseCMK                : kms:Decrypt/GenerateDataKey/DescribeKey on the
#                             resolved CMK with a kms:ViaService condition
#                             pinned to bedrock.<region>.amazonaws.com and
#                             logs.<region>.amazonaws.com.
#   - XRayTracing           : xray:PutTraceSegments/PutTelemetryRecords on "*".
#                             X-Ray does NOT support resource-level permissions
#                             for these two actions; this is the ONLY wildcard
#                             in the module's IAM policy and is documented in
#                             design.md §7 as a constitution deviation.
#
# Statements emitted conditionally:
#   - InvokeActionGroupLambdas : when length(var.action_group_definitions) > 0
#                                and at least one entry supplies a lambda_arn,
#                                lambda:InvokeFunction on those Lambda ARNs.
#   - RetrieveFromKnowledgeBase: when var.enable_knowledge_base, scoped to
#                                local.kb_arn_pattern (a region+account scoped
#                                wildcard) — using the live KB resource ARN
#                                here would create a forward reference to
#                                Item E and break terraform validate today.
#   - ApplyGuardrail           : when var.guardrail_id != "", scoped to the
#                                consumer-provided guardrail ARN.
###############################################################################

data "aws_iam_policy_document" "agent_inline" {
  statement {
    sid       = "InvokeFoundationModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [local.foundation_model_arn]
  }

  statement {
    sid       = "WriteAgentLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.agent_log_group_arn}:*"]
  }

  statement {
    sid       = "UseCMK"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [local.kms_key_arn_resolved]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "bedrock.${local.region}.amazonaws.com",
        "logs.${local.region}.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "XRayTracing"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions; see AWS X-Ray IAM docs.
  }

  # Conditional: action-group Lambda invoke. Only emitted when at least one
  # action_group_definitions entry actually supplies a lambda_arn.
  dynamic "statement" {
    for_each = length(local.action_group_lambda_arns) > 0 ? [1] : []
    content {
      sid       = "InvokeActionGroupLambdas"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = local.action_group_lambda_arns

      condition {
        test     = "StringEquals"
        variable = "AWS:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  # Conditional: knowledge-base retrieval. Scoped to a region+account wildcard
  # rather than the live aws_bedrockagent_knowledge_base.this[0].arn so that
  # main.tf validates before Item E creates the KB resource. The KB this module
  # creates is named "${var.agent_name}-kb" and lives in the caller's account
  # and region, so the wildcard does not over-grant in practice.
  dynamic "statement" {
    for_each = var.enable_knowledge_base ? [1] : []
    content {
      sid       = "RetrieveFromKnowledgeBase"
      effect    = "Allow"
      actions   = ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"]
      resources = [local.kb_arn_pattern]
    }
  }

  # Conditional: guardrail application. Only emitted when guardrail_id is set.
  dynamic "statement" {
    for_each = var.guardrail_id == "" ? [] : [1]
    content {
      sid       = "ApplyGuardrail"
      effect    = "Allow"
      actions   = ["bedrock:ApplyGuardrail"]
      resources = [local.guardrail_arn]
    }
  }
}

###############################################################################
# Module-managed CMK key policy (only used when local.create_kms is true).
#
# Statements:
#   - EnableRootAdmin : account-root principal gets kms:* so admins retain
#                       break-glass control of the key.
#   - AllowBedrock    : bedrock.amazonaws.com gets Decrypt/GenerateDataKey*/
#                       DescribeKey with aws:SourceAccount + kms:ViaService
#                       confused-deputy conditions.
#   - AllowCWLogs     : regional logs.<region>.amazonaws.com service principal
#                       gets the standard log-encryption action set with a
#                       kms:EncryptionContext:aws:logs:arn condition pinned
#                       to /aws/bedrock/agents/* in this account.
###############################################################################

data "aws_iam_policy_document" "kms" {
  count = local.create_kms ? 1 : 0

  statement {
    sid       = "EnableRootAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowBedrock"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["bedrock.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowCWLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock/agents/*"]
    }
  }
}

###############################################################################
# Knowledge base execution role — trust policy.
#
# Mirrors the agent trust policy: bedrock.amazonaws.com service principal with
# both confused-deputy guards (aws:SourceAccount = caller account, aws:SourceArn
# ArnLike-pinned to any knowledge-base in the caller's region). Reference: AWS
# Bedrock User Guide — kb-permissions.html.
###############################################################################

data "aws_iam_policy_document" "kb_assume" {
  count = var.enable_knowledge_base ? 1 : 0

  statement {
    sid     = "BedrockKBAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"]
    }
  }
}

###############################################################################
# Knowledge base execution role — inline policy (least-privilege).
#
# Statements:
#   - InvokeEmbeddingModel : bedrock:InvokeModel on the embedding model ARN
#                            (Titan v2 by default).
#   - S3Read              : s3:GetObject on every object in the consumer-supplied
#                            bucket. When var.knowledge_base_inclusion_prefixes
#                            is non-empty, GetObject is scoped via object-level
#                            ARNs and ListBucket is scoped via the s3:prefix
#                            condition; otherwise both are bucket-wide.
#   - UseKBKMS            : kms:Decrypt + kms:DescribeKey on the resolved CMK.
#                            Used by Bedrock to decrypt KB-managed assets that
#                            ride the same key as the agent log group / agent.
#   - UseSourceBucketKMS  : kms:Decrypt + kms:DescribeKey on
#                            var.knowledge_base_s3_kms_key_arn when the source
#                            bucket uses a separate CMK (consumer responsibility
#                            to also mirror the grant in the bucket key policy).
#   - AOSSAPIAccess       : aoss:APIAccessAll on the AOSS collection ARN. AOSS
#                            uses a SigV4 data-plane API; this is the IAM-side
#                            grant; the data-access policy below is the AOSS
#                            collection-side grant. BOTH are required.
###############################################################################

data "aws_iam_policy_document" "kb_inline" {
  count = var.enable_knowledge_base ? 1 : 0

  statement {
    sid       = "InvokeEmbeddingModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.embedding_model_arn]
  }

  # ListBucket is bucket-level; GetObject is object-level. Optional s3:prefix
  # condition narrows ingestion to a known set of folders.
  statement {
    sid       = "S3ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.knowledge_base_s3_bucket_arn]

    dynamic "condition" {
      for_each = length(var.knowledge_base_inclusion_prefixes) > 0 ? [1] : []
      content {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = [for p in var.knowledge_base_inclusion_prefixes : "${p}*"]
      }
    }
  }

  statement {
    sid     = "S3GetObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = length(var.knowledge_base_inclusion_prefixes) > 0 ? [
      for p in var.knowledge_base_inclusion_prefixes : "${var.knowledge_base_s3_bucket_arn}/${p}*"
    ] : ["${var.knowledge_base_s3_bucket_arn}/*"]
  }

  statement {
    sid       = "UseKBKMS"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [local.kms_key_arn_resolved]
  }

  # Optional: grant decrypt on a separate CMK that the source S3 bucket uses.
  dynamic "statement" {
    for_each = var.knowledge_base_s3_kms_key_arn == "" ? [] : [1]
    content {
      sid       = "UseSourceBucketKMS"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = [var.knowledge_base_s3_kms_key_arn]
    }
  }

  statement {
    sid       = "AOSSAPIAccess"
    effect    = "Allow"
    actions   = ["aoss:APIAccessAll"]
    resources = [aws_opensearchserverless_collection.kb[0].arn]
  }
}

###############################################################################
# Invoker Lambda execution role — trust policy (Item F).
#
# Standard lambda.amazonaws.com sts:AssumeRole. The Lambda runs as a singleton
# behind API Gateway and is not invoked by another AWS service that would
# benefit from the SourceAccount/SourceArn confused-deputy guards (apigateway
# invokes via the resource-policy permission, not via assume-role chaining).
###############################################################################

data "aws_iam_policy_document" "lambda_assume" {
  count = var.enable_api_gateway ? 1 : 0

  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

###############################################################################
# Invoker Lambda execution role — inline policy (Item F).
#
# Statements:
#   - WriteInvokerLogs    : logs:CreateLogStream/PutLogEvents on the invoker
#                           log group ARN with stream wildcard.
#   - InvokeBedrockAgent  : bedrock:InvokeAgent scoped to the agent alias ARN
#                           created by this module (NOT a wildcard) — the only
#                           runtime privilege the invoker needs.
#   - XRayTracing         : xray:PutTraceSegments / PutTelemetryRecords on "*".
#                           X-Ray does NOT support resource-level permissions
#                           for these two actions; this is the same documented
#                           wildcard exception that appears in the agent role
#                           (see design.md §7).
#   - UseCMK              : kms:Decrypt + kms:GenerateDataKey on the resolved
#                           CMK so the invoker can read the agent-side
#                           encrypted state and write KMS-encrypted log events.
###############################################################################

data "aws_iam_policy_document" "lambda_inline" {
  count = var.enable_api_gateway ? 1 : 0

  statement {
    sid       = "WriteInvokerLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[0].arn}:*"]
  }

  statement {
    sid       = "InvokeBedrockAgent"
    effect    = "Allow"
    actions   = ["bedrock:InvokeAgent"]
    resources = [aws_bedrockagent_agent_alias.this.agent_alias_arn]
  }

  statement {
    sid       = "XRayTracing"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions; see AWS X-Ray IAM docs.
  }

  statement {
    sid       = "UseCMK"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [local.kms_key_arn_resolved]
  }
}
