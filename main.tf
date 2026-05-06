###############################################################################
# main.tf — core (always-present) resources for the bedrock-agentcore module.
#
# This module follows the standard root-module structure:
#   - versions.tf        : Terraform + provider version constraints
#   - variables.tf       : Input variable declarations
#   - data.tf            : Account / partition / region context + IAM docs
#   - locals.tf          : Required tags, derived ARNs, conditional flags
#   - main.tf            : Core resources (this file) — KMS, log group, IAM
#                          execution role, agent, code interpreter action group,
#                          alias, and Lambda-backed action groups + permissions.
#   - knowledge_base.tf  : All `var.enable_knowledge_base ? 1 : 0` resources
#                          (Item E). See file for the full inventory.
#   - api_gateway.tf     : All `var.enable_api_gateway ? 1 : 0` resources
#                          (Item F). See file for the full inventory.
#   - outputs.tf         : Output value declarations
#
# The split exists so each file stays under the constitution §2.1 500-line cap;
# resources are organised by checklist item to keep ownership obvious.
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
# Knowledge base resources  (Item E) — see knowledge_base.tf
# -----------------------------------------------------------------------------
# All `var.enable_knowledge_base ? 1 : 0` resources (IAM kb role, kb policy,
# AOSS encryption + network security policies, AOSS collection, AOSS data
# access policy, time_sleep.wait_aoss_dap, opensearch_index, KB resource, S3
# data source, and the agent <-> KB association) live in knowledge_base.tf to
# keep this file under the §2.1 file-size cap.

# -----------------------------------------------------------------------------
# API Gateway HTTP front door  (Item F) — see api_gateway.tf
# -----------------------------------------------------------------------------
# All `var.enable_api_gateway ? 1 : 0` resources (Lambda execution role + inline
# policy, Lambda log group, invoker Lambda function, API Gateway v2 HTTP API
# with optional cors_configuration, route, integration, stage, access log group,
# and the apigateway -> lambda invoke permission) live in api_gateway.tf.
