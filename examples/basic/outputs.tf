output "agent_id" {
  description = "Unique identifier of the Bedrock Agent"
  value       = module.bedrock_agent.agent_id
}

output "agent_arn" {
  description = "Full ARN of the Bedrock Agent"
  value       = module.bedrock_agent.agent_arn
}

output "agent_alias_arn" {
  description = "Full ARN of the agent alias used for invocation"
  value       = module.bedrock_agent.agent_alias_arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for encryption"
  value       = module.bedrock_agent.kms_key_arn
}

output "log_group_name" {
  description = "Name of the CloudWatch log group"
  value       = module.bedrock_agent.log_group_name
}
