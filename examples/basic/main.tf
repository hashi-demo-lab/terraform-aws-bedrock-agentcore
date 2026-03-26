# Basic Example: Minimal Bedrock Agent
#
# This example creates a Bedrock Agent with the minimum required inputs.
# The module applies secure defaults automatically:
#   - KMS encryption (module-created key)
#   - CloudWatch logging (90-day retention)
#   - Code interpreter enabled (default)
#   - No public API endpoint
#   - Least-privilege IAM role

provider "aws" {
  region = var.region
}

module "bedrock_agent" {
  source = "../../"

  agent_name          = "basic-assistant"
  foundation_model_id = "anthropic.claude-3-5-sonnet-20241022-v2:0"
  agent_instruction   = "You are a helpful assistant that answers questions about cloud infrastructure. Be concise and accurate in your responses."
  environment         = "dev"
  owner               = "platform-team"
  cost_center         = "CC-1234"
}
