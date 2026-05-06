###############################################################################
# Account / partition / region context used to build derived ARNs and IAM
# confused-deputy conditions throughout the module.
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

# NOTE: archive_file.invoker_zip is intentionally deferred to checklist Item F,
# which also creates files/invoker/index.py. Declaring the data source before
# the source file exists would fail terraform validate.

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
