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
# aws_bedrockagent_agent_action_group.lambda  — for_each = var.action_group_definitions
# aws_lambda_permission.bedrock_invoke        — for_each = var.action_group_definitions

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

# -----------------------------------------------------------------------------
# API Gateway HTTP front door + invoker Lambda  (Item F)
# -----------------------------------------------------------------------------
# aws_iam_role.lambda                  — count = var.enable_api_gateway ? 1 : 0
# aws_iam_role_policy.lambda           — count = var.enable_api_gateway ? 1 : 0
# aws_cloudwatch_log_group.lambda      — count = var.enable_api_gateway ? 1 : 0
# aws_lambda_function.invoker          — count = var.enable_api_gateway ? 1 : 0
# aws_apigatewayv2_api.this            — count = var.enable_api_gateway ? 1 : 0
# aws_apigatewayv2_integration.lambda  — count = var.enable_api_gateway ? 1 : 0
# aws_apigatewayv2_route.invoke        — count = var.enable_api_gateway ? 1 : 0
# aws_cloudwatch_log_group.apigw_access — count = var.enable_api_gateway ? 1 : 0
# aws_apigatewayv2_stage.default       — count = var.enable_api_gateway ? 1 : 0
# aws_lambda_permission.apigw_invoke   — count = var.enable_api_gateway ? 1 : 0
