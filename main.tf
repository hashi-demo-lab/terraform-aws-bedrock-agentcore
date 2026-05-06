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
