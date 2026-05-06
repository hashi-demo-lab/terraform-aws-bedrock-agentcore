# Generated from specs/001-bedrock-agentcore/design.md Section 5
# integration
#
# Integration tests use REAL providers with command = apply. Creates and destroys
# real AWS infrastructure (agent + log group + IAM + KMS at minimum). Requires
# AWS credentials and accepts a real AWS bill. Not run during unit validation.
#
# Each assertion below is marked `# integration` per the design's marker convention.

# Scenario: "Integration - End-to-End"
run "integration_end_to_end" {
  command = apply

  variables {
    agent_name       = "integration-test-agent"
    instruction      = "You are a helpful assistant. Answer user questions clearly and concisely. Use the code interpreter only when computation is required."
    foundation_model = "anthropic.claude-3-5-sonnet-20241022-v2:0"
    environment      = "test"
    owner            = "team-genai@example.com"
    cost_center      = "cc-1234"
    project          = "agentcore-tests"
    force_destroy    = true
  }

  # integration
  assert {
    condition     = aws_bedrockagent_agent.this.agent_status == "PREPARED"
    error_message = "Agent must reach PREPARED state after apply."
  }

  # integration
  assert {
    condition     = can(regex("^[0-9]+$", aws_bedrockagent_agent.this.agent_version))
    error_message = "Agent version must be numeric (not DRAFT) after prepare."
  }

  # integration
  assert {
    condition     = aws_bedrockagent_agent_alias.this.agent_alias_id != ""
    error_message = "Agent alias must resolve to a non-empty alias id."
  }

  # integration
  assert {
    condition     = aws_kms_key.this[0].is_enabled == true
    error_message = "Module-created KMS key must be enabled."
  }

  # integration
  assert {
    condition     = aws_cloudwatch_log_group.agent.id != ""
    error_message = "Agent log group must exist in CloudWatch."
  }

  # integration
  assert {
    condition     = output.agent_alias_arn != null && output.agent_alias_arn != ""
    error_message = "Output agent_alias_arn must be populated after apply."
  }

  # integration
  assert {
    condition     = output.kms_key_arn != null && output.kms_key_arn != ""
    error_message = "Output kms_key_arn must be populated after apply."
  }

  # integration
  assert {
    condition     = output.knowledge_base_id == null
    error_message = "Output knowledge_base_id must be null when KB is disabled."
  }

  # integration
  assert {
    condition     = output.api_endpoint == null
    error_message = "Output api_endpoint must be null when API GW is disabled."
  }
}
