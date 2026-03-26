output "agent_id" {
  description = "Unique identifier of the Bedrock Agent"
  value       = module.bedrock_agent.agent_id
}

output "agent_arn" {
  description = "Full ARN of the Bedrock Agent"
  value       = module.bedrock_agent.agent_arn
}

output "agent_alias_id" {
  description = "Identifier of the agent alias used for invocation"
  value       = module.bedrock_agent.agent_alias_id
}

output "agent_alias_arn" {
  description = "Full ARN of the agent alias used for invocation"
  value       = module.bedrock_agent.agent_alias_arn
}

output "agent_role_arn" {
  description = "ARN of the IAM role used by the agent"
  value       = module.bedrock_agent.agent_role_arn
}

output "knowledge_base_id" {
  description = "Identifier of the knowledge base (null when disabled)"
  value       = module.bedrock_agent.knowledge_base_id
}

output "knowledge_base_arn" {
  description = "ARN of the knowledge base (null when disabled)"
  value       = module.bedrock_agent.knowledge_base_arn
}

output "api_endpoint" {
  description = "HTTP API Gateway endpoint URL"
  value       = module.bedrock_agent.api_endpoint
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for encryption"
  value       = module.bedrock_agent.kms_key_arn
}

output "log_group_name" {
  description = "Name of the CloudWatch log group"
  value       = module.bedrock_agent.log_group_name
}

output "guardrail_id" {
  description = "ID of the module-created guardrail"
  value       = module.bedrock_agent.guardrail_id
}

output "guardrail_version" {
  description = "Version of the module-created guardrail"
  value       = module.bedrock_agent.guardrail_version
}
