###############################################################################
# Outputs: agent identity (always present)
###############################################################################

output "agent_id" {
  description = "Short identifier of the Bedrock agent (e.g., GGRRAED6JP). Use this in cross-resource references."
  value       = aws_bedrockagent_agent.this.agent_id
}

output "agent_arn" {
  description = "Full ARN of the Bedrock agent."
  value       = aws_bedrockagent_agent.this.agent_arn
}

output "agent_version" {
  description = "Current prepared agent version (numeric, e.g., \"1\")."
  value       = aws_bedrockagent_agent.this.agent_version
}

output "agent_alias_id" {
  description = "Identifier of the stable invocation alias."
  value       = aws_bedrockagent_agent_alias.this.agent_alias_id
}

output "agent_alias_arn" {
  description = "Full ARN of the agent alias — the invocation target consumers should use with bedrock-agent-runtime:InvokeAgent."
  value       = aws_bedrockagent_agent_alias.this.agent_alias_arn
}

output "agent_role_arn" {
  description = "ARN of the agent execution role for downstream IAM policy references."
  value       = aws_iam_role.agent.arn
}

###############################################################################
# Outputs: KMS + logging (always present)
###############################################################################

output "kms_key_arn" {
  description = "ARN of the KMS CMK used for at-rest encryption (created by the module or passed in)."
  value       = local.kms_key_arn_resolved
}

output "log_group_name" {
  description = "Name of the agent CloudWatch log group."
  value       = aws_cloudwatch_log_group.agent.name
}

output "log_group_arn" {
  description = "ARN of the agent CloudWatch log group."
  value       = aws_cloudwatch_log_group.agent.arn
}

###############################################################################
# Outputs: Knowledge base (conditional on var.enable_knowledge_base)
###############################################################################

output "knowledge_base_id" {
  description = "Identifier of the Bedrock knowledge base, or null when disabled."
  value       = try(aws_bedrockagent_knowledge_base.this[0].id, null)
}

output "knowledge_base_arn" {
  description = "ARN of the Bedrock knowledge base, or null when disabled."
  value       = try(aws_bedrockagent_knowledge_base.this[0].arn, null)
}

output "knowledge_base_role_arn" {
  description = "ARN of the KB execution role."
  value       = try(aws_iam_role.kb[0].arn, null)
}

output "data_source_id" {
  description = "Identifier of the KB S3 data source — needed to trigger ingestion via the SDK (StartIngestionJob)."
  value       = try(aws_bedrockagent_data_source.this[0].data_source_id, null)
}

output "opensearch_collection_arn" {
  description = "ARN of the AOSS vector collection."
  value       = try(aws_opensearchserverless_collection.kb[0].arn, null)
}

###############################################################################
# Outputs: API Gateway HTTP front door (conditional on var.enable_api_gateway)
###############################################################################

output "api_id" {
  description = "API Gateway v2 HTTP API identifier. Use with aws_apigatewayv2_authorizer to attach an authorizer."
  value       = try(aws_apigatewayv2_api.this[0].id, null)
}

output "api_endpoint" {
  description = "Invoke URL of the HTTP API (https://<id>.execute-api.<region>.amazonaws.com)."
  value       = try(aws_apigatewayv2_api.this[0].api_endpoint, null)
}

output "api_arn" {
  description = "ARN of the API Gateway HTTP API for resource policies / WAFv2 association."
  value       = try(aws_apigatewayv2_api.this[0].arn, null)
}

output "api_execution_arn" {
  description = "Execution ARN of the API for aws_lambda_permission.source_arn if the consumer adds more integrations."
  value       = try(aws_apigatewayv2_api.this[0].execution_arn, null)
}

output "default_route_key" {
  description = "The default route key (POST /invoke) — used by consumers when overriding authorization_type via aws_apigatewayv2_route."
  value       = try(aws_apigatewayv2_route.invoke[0].route_key, null)
}

output "invoker_lambda_arn" {
  description = "ARN of the bundled invoker Lambda function."
  value       = try(aws_lambda_function.invoker[0].arn, null)
}

output "invoker_lambda_name" {
  description = "Name of the bundled invoker Lambda function."
  value       = try(aws_lambda_function.invoker[0].function_name, null)
}
