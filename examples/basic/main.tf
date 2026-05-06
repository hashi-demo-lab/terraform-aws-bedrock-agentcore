###############################################################################
# examples/basic/main.tf
#
# Minimal usage of the bedrock-agentcore module: a Bedrock agent with the
# AWS-managed code interpreter action group, module-managed KMS CMK, default
# log retention, no knowledge base, no API Gateway. All other defaults apply.
#
# Apply with:
#   terraform init
#   terraform apply
#
# Per constitution §2.1, provider blocks live in EXAMPLES, not in the root
# module. The module inherits this provider configuration at call time.
###############################################################################

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "agent" {
  source = "../.."

  agent_name  = "basic-demo"
  instruction = "You are a helpful assistant. Answer the user's questions clearly and concisely. When the user asks for calculations or code, prefer the code interpreter tool to compute the answer rather than guessing."

  # Required organizational tags
  environment = "sandbox"
  owner       = "platform-team@example.com"
  cost_center = "CC-1234"
  project     = "agent-poc"
}

###############################################################################
# Outputs — surface the most useful identifiers from the module
###############################################################################

output "agent_alias_arn" {
  description = "Invocation target — pass this to bedrock-agent-runtime:InvokeAgent."
  value       = module.agent.agent_alias_arn
}

output "kms_key_arn" {
  description = "ARN of the module-created KMS CMK used for at-rest encryption."
  value       = module.agent.kms_key_arn
}

output "log_group_name" {
  description = "Name of the agent CloudWatch log group."
  value       = module.agent.log_group_name
}
