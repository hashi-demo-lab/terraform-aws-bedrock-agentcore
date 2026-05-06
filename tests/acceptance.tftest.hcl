# Generated from specs/001-bedrock-agentcore/design.md Section 5
# acceptance
#
# Acceptance tests use REAL providers with command = plan to validate computed
# attributes, ARN formats, and provider-resolved references that unit tests
# (with mock providers) cannot check. Requires AWS credentials. Not run during
# unit validation.
#
# Each assertion below is marked `# acceptance` per the design's marker convention.

# Scenario: "Acceptance - Plan Verification"
run "acceptance_plan_verification" {
  command = plan

  variables {
    agent_name       = "acceptance-test-agent"
    instruction      = "You are a helpful assistant. Answer user questions clearly and concisely. Use the code interpreter only when computation is required."
    foundation_model = "anthropic.claude-3-5-sonnet-20241022-v2:0"
    environment      = "test"
    owner            = "team-genai@example.com"
    cost_center      = "cc-1234"
    project          = "agentcore-tests"
  }

  # acceptance
  assert {
    condition     = can(regex("^arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:agent/[A-Z0-9]+$", aws_bedrockagent_agent.this.agent_arn))
    error_message = "Agent ARN must match Bedrock agent ARN format."
  }

  # acceptance
  assert {
    condition     = can(regex("^arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:agent-alias/[A-Z0-9]+/[A-Z0-9]+$", aws_bedrockagent_agent_alias.this.agent_alias_arn))
    error_message = "Agent alias ARN must match Bedrock agent-alias ARN format."
  }

  # acceptance
  assert {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", aws_kms_key.this[0].arn))
    error_message = "KMS key ARN must match expected KMS key ARN format."
  }

  # acceptance
  assert {
    condition     = can(regex("^arn:aws:logs:[a-z0-9-]+:[0-9]{12}:log-group:/aws/bedrock/agents/acceptance-test-agent:.*$", aws_cloudwatch_log_group.agent.arn))
    error_message = "Agent log group ARN must follow the /aws/bedrock/agents/<agent_name> convention."
  }

  # acceptance
  assert {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", aws_iam_role.agent.arn))
    error_message = "Agent IAM role ARN must match the IAM role ARN format."
  }

  # acceptance
  assert {
    condition     = length(regexall("foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0", aws_iam_role_policy.agent.policy)) > 0
    error_message = "Agent inline policy must contain the foundation model ARN reference."
  }

  # acceptance
  assert {
    condition     = length(regexall("lambda:InvokeFunction", aws_iam_role_policy.agent.policy)) == 0
    error_message = "When no action groups are configured, the inline policy must NOT contain lambda:InvokeFunction."
  }

  # acceptance
  assert {
    condition     = length(regexall("aws:SourceAccount", aws_iam_role.agent.assume_role_policy)) > 0
    error_message = "Agent trust policy must include aws:SourceAccount confused-deputy guard."
  }
}
