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
# aws_kms_key.this        — count = local.create_kms ? 1 : 0
# aws_kms_alias.this      — count = local.create_kms ? 1 : 0

# -----------------------------------------------------------------------------
# CloudWatch log group for the agent  (Item B)
# -----------------------------------------------------------------------------
# aws_cloudwatch_log_group.agent — always

# -----------------------------------------------------------------------------
# IAM execution role for the Bedrock agent  (Item B)
# -----------------------------------------------------------------------------
# aws_iam_role.agent          — always
# aws_iam_role_policy.agent   — always

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
