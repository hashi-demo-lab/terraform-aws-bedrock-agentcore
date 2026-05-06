###############################################################################
# Outputs: agent identity (always present)
###############################################################################

output "agent_id" {
  description = "Short identifier of the Bedrock agent (e.g., GGRRAED6JP). Use this in cross-resource references."
  # TODO: wire to aws_bedrockagent_agent.this.agent_id in Item C
  value = null
}

output "agent_arn" {
  description = "Full ARN of the Bedrock agent."
  # TODO: wire to aws_bedrockagent_agent.this.agent_arn in Item C
  value = null
}

output "agent_version" {
  description = "Current prepared agent version (numeric, e.g., \"1\")."
  # TODO: wire to aws_bedrockagent_agent.this.agent_version in Item C
  value = null
}

output "agent_alias_id" {
  description = "Identifier of the stable invocation alias."
  # TODO: wire to aws_bedrockagent_agent_alias.this.agent_alias_id in Item C
  value = null
}

output "agent_alias_arn" {
  description = "Full ARN of the agent alias — the invocation target consumers should use with bedrock-agent-runtime:InvokeAgent."
  # TODO: wire to aws_bedrockagent_agent_alias.this.agent_alias_arn in Item C
  value = null
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
  # TODO: wire to try(aws_bedrockagent_knowledge_base.this[0].id, null) in Item E
  value = try(null, null)
}

output "knowledge_base_arn" {
  description = "ARN of the Bedrock knowledge base, or null when disabled."
  # TODO: wire to try(aws_bedrockagent_knowledge_base.this[0].arn, null) in Item E
  value = try(null, null)
}

output "knowledge_base_role_arn" {
  description = "ARN of the KB execution role."
  # TODO: wire to try(aws_iam_role.kb[0].arn, null) in Item E
  value = try(null, null)
}

output "data_source_id" {
  description = "Identifier of the KB S3 data source — needed to trigger ingestion via the SDK (StartIngestionJob)."
  # TODO: wire to try(aws_bedrockagent_data_source.this[0].data_source_id, null) in Item E
  value = try(null, null)
}

output "opensearch_collection_arn" {
  description = "ARN of the AOSS vector collection."
  # TODO: wire to try(aws_opensearchserverless_collection.kb[0].arn, null) in Item E
  value = try(null, null)
}

###############################################################################
# Outputs: API Gateway HTTP front door (conditional on var.enable_api_gateway)
###############################################################################

output "api_id" {
  description = "API Gateway v2 HTTP API identifier. Use with aws_apigatewayv2_authorizer to attach an authorizer."
  # TODO: wire to try(aws_apigatewayv2_api.this[0].id, null) in Item F
  value = try(null, null)
}

output "api_endpoint" {
  description = "Invoke URL of the HTTP API (https://<id>.execute-api.<region>.amazonaws.com)."
  # TODO: wire to try(aws_apigatewayv2_api.this[0].api_endpoint, null) in Item F
  value = try(null, null)
}

output "api_arn" {
  description = "ARN of the API Gateway HTTP API for resource policies / WAFv2 association."
  # TODO: wire to try(aws_apigatewayv2_api.this[0].arn, null) in Item F
  value = try(null, null)
}

output "api_execution_arn" {
  description = "Execution ARN of the API for aws_lambda_permission.source_arn if the consumer adds more integrations."
  # TODO: wire to try(aws_apigatewayv2_api.this[0].execution_arn, null) in Item F
  value = try(null, null)
}

output "default_route_key" {
  description = "The default route key (POST /invoke) — used by consumers when overriding authorization_type via aws_apigatewayv2_route."
  # TODO: wire to try(aws_apigatewayv2_route.invoke[0].route_key, null) in Item F
  value = try(null, null)
}

output "invoker_lambda_arn" {
  description = "ARN of the bundled invoker Lambda function."
  # TODO: wire to try(aws_lambda_function.invoker[0].arn, null) in Item F
  value = try(null, null)
}

output "invoker_lambda_name" {
  description = "Name of the bundled invoker Lambda function."
  # TODO: wire to try(aws_lambda_function.invoker[0].function_name, null) in Item F
  value = try(null, null)
}
