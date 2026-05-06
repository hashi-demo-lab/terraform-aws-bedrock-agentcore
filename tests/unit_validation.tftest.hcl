# Generated from specs/001-bedrock-agentcore/design.md Section 5

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDAJDPLRKLG7UEXAMPLE"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }
}

mock_provider "time" {}

mock_provider "opensearch" {}

mock_provider "archive" {
  mock_data "archive_file" {
    defaults = {
      output_path         = "/tmp/invoker.zip"
      output_size         = 1024
      output_sha          = "abc123def456"
      output_base64sha256 = "bW9ja2VkLXNoYS0yNTYtdmFsdWU="
      output_md5          = "d41d8cd98f00b204e9800998ecf8427e"
    }
  }
}

###############################################################################
# Validation Errors (reject cases) — one run block per invalid input
###############################################################################

# Scenario: "Validation Errors - agent_name = \"\" (length validation rejects)"
run "test_agent_name_empty_rejected" {
  command = plan

  variables {
    agent_name  = ""
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.agent_name]
}

# Scenario: "Validation Errors - agent_name = \"has spaces\" (regex rejects)"
run "test_agent_name_with_spaces_rejected" {
  command = plan

  variables {
    agent_name  = "has spaces"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.agent_name]
}

# Scenario: "Validation Errors - agent_name 101 chars (length max rejects)"
run "test_agent_name_too_long_rejected" {
  command = plan

  variables {
    # 101 'a' characters
    agent_name  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.agent_name]
}

# Scenario: "Validation Errors - instruction = \"too short\" (40-char minimum rejects)"
run "test_instruction_too_short_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "too short"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.instruction]
}

# Scenario: "Validation Errors - instruction 20001 chars (20000-char maximum rejects)"
run "test_instruction_too_long_rejected" {
  command = plan

  variables {
    agent_name = "test"
    # 20001 'a' chars: build via 200 reps of 100-char strings + 1 char (constructed at parse time)
    instruction = "${join("", [for i in range(200) : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])}a"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.instruction]
}

# Scenario: "Validation Errors - idle_session_ttl_seconds = 30 (below 60 minimum rejects)"
run "test_idle_session_ttl_too_low_rejected" {
  command = plan

  variables {
    agent_name               = "test"
    instruction              = "This is a perfectly valid instruction string of forty plus characters."
    idle_session_ttl_seconds = 30
    environment              = "test"
    owner                    = "x@y.z"
    cost_center              = "c"
    project                  = "p"
  }

  expect_failures = [var.idle_session_ttl_seconds]
}

# Scenario: "Validation Errors - idle_session_ttl_seconds = 7200 (above 3600 maximum rejects)"
run "test_idle_session_ttl_too_high_rejected" {
  command = plan

  variables {
    agent_name               = "test"
    instruction              = "This is a perfectly valid instruction string of forty plus characters."
    idle_session_ttl_seconds = 7200
    environment              = "test"
    owner                    = "x@y.z"
    cost_center              = "c"
    project                  = "p"
  }

  expect_failures = [var.idle_session_ttl_seconds]
}

# Scenario: "Validation Errors - log_retention_days = 45 (not in CloudWatch-allowed list rejects)"
run "test_log_retention_days_45_rejected" {
  command = plan

  variables {
    agent_name         = "test"
    instruction        = "This is a perfectly valid instruction string of forty plus characters."
    log_retention_days = 45
    environment        = "test"
    owner              = "x@y.z"
    cost_center        = "c"
    project            = "p"
  }

  expect_failures = [var.log_retention_days]
}

# Scenario: "Validation Errors - log_retention_days = 0 (not in CloudWatch-allowed list rejects)"
run "test_log_retention_days_zero_rejected" {
  command = plan

  variables {
    agent_name         = "test"
    instruction        = "This is a perfectly valid instruction string of forty plus characters."
    log_retention_days = 0
    environment        = "test"
    owner              = "x@y.z"
    cost_center        = "c"
    project            = "p"
  }

  expect_failures = [var.log_retention_days]
}

# Scenario: "Validation Errors - wait_after_prepare_seconds = -1 (below 0 rejects)"
run "test_wait_after_prepare_negative_rejected" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    wait_after_prepare_seconds = -1
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  expect_failures = [var.wait_after_prepare_seconds]
}

# Scenario: "Validation Errors - wait_after_prepare_seconds = 200 (above 120 rejects)"
run "test_wait_after_prepare_too_high_rejected" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    wait_after_prepare_seconds = 200
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  expect_failures = [var.wait_after_prepare_seconds]
}

# Scenario: "Validation Errors - api_throttling_rate_limit = 0 (not strictly positive rejects)"
run "test_api_throttling_rate_limit_zero_rejected" {
  command = plan

  variables {
    agent_name                = "test"
    instruction               = "This is a perfectly valid instruction string of forty plus characters."
    api_throttling_rate_limit = 0
    environment               = "test"
    owner                     = "x@y.z"
    cost_center               = "c"
    project                   = "p"
  }

  expect_failures = [var.api_throttling_rate_limit]
}

# Scenario: "Validation Errors - api_throttling_rate_limit = 20000 (above 10000 rejects)"
run "test_api_throttling_rate_limit_too_high_rejected" {
  command = plan

  variables {
    agent_name                = "test"
    instruction               = "This is a perfectly valid instruction string of forty plus characters."
    api_throttling_rate_limit = 20000
    environment               = "test"
    owner                     = "x@y.z"
    cost_center               = "c"
    project                   = "p"
  }

  expect_failures = [var.api_throttling_rate_limit]
}

# Scenario: "Validation Errors - environment = \"production\" (not in allowed set rejects)"
run "test_environment_production_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "production"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.environment]
}

# Scenario: "Validation Errors - owner = \"\" (length minimum rejects)"
run "test_owner_empty_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = ""
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.owner]
}

# Scenario: "Validation Errors - cost_center = \"\" (length minimum rejects)"
run "test_cost_center_empty_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = ""
    project     = "p"
  }

  expect_failures = [var.cost_center]
}

# Scenario: "Validation Errors - project = \"\" (length minimum rejects)"
run "test_project_empty_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = ""
  }

  expect_failures = [var.project]
}

# Scenario: "Validation Errors - kms_key_arn = \"not-an-arn\" (regex rejects)"
run "test_kms_key_arn_invalid_format_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    kms_key_arn = "not-an-arn"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.kms_key_arn]
}

# Scenario: "Validation Errors - knowledge_base_s3_bucket_arn = \"not-an-arn\" with enable_knowledge_base = true (regex + non-empty rejects)"
run "test_knowledge_base_s3_bucket_arn_invalid_rejected" {
  command = plan

  variables {
    agent_name                   = "test"
    instruction                  = "This is a perfectly valid instruction string of forty plus characters."
    enable_knowledge_base        = true
    knowledge_base_s3_bucket_arn = "not-an-arn"
    environment                  = "test"
    owner                        = "x@y.z"
    cost_center                  = "c"
    project                      = "p"
  }

  expect_failures = [var.knowledge_base_s3_bucket_arn]
}

# Scenario: "Validation Errors - enable_knowledge_base = true with knowledge_base_s3_bucket_arn = \"\" (custom validation: required when KB enabled)"
run "test_knowledge_base_s3_bucket_arn_required_when_enabled_rejected" {
  command = plan

  variables {
    agent_name                   = "test"
    instruction                  = "This is a perfectly valid instruction string of forty plus characters."
    enable_knowledge_base        = true
    knowledge_base_s3_bucket_arn = ""
    environment                  = "test"
    owner                        = "x@y.z"
    cost_center                  = "c"
    project                      = "p"
  }

  expect_failures = [var.knowledge_base_s3_bucket_arn]
}

# Scenario: "Validation Errors - guardrail_id = \"INVALID-CASE\" (regex rejects uppercase + dash)"
run "test_guardrail_id_invalid_chars_rejected" {
  command = plan

  variables {
    agent_name   = "test"
    instruction  = "This is a perfectly valid instruction string of forty plus characters."
    guardrail_id = "INVALID-CASE"
    environment  = "test"
    owner        = "x@y.z"
    cost_center  = "c"
    project      = "p"
  }

  expect_failures = [var.guardrail_id]
}

# Scenario: "Validation Errors - guardrail_version = \"v1\" with guardrail_id != \"\" (regex rejects)"
run "test_guardrail_version_invalid_format_rejected" {
  command = plan

  variables {
    agent_name        = "test"
    instruction       = "This is a perfectly valid instruction string of forty plus characters."
    guardrail_id      = "abc123"
    guardrail_version = "v1"
    environment       = "test"
    owner             = "x@y.z"
    cost_center       = "c"
    project           = "p"
  }

  expect_failures = [var.guardrail_version]
}

# Scenario: "Validation Errors - action_group with neither api_schema nor function_schema (custom validation rejects)"
run "test_action_group_missing_schema_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    action_group_definitions = {
      "bad" = {
        description = "x"
        lambda_arn  = "arn:aws:lambda:us-east-1:123456789012:function:bad"
      }
    }
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.action_group_definitions]
}

# Scenario: "Validation Errors - action_group api_schema with both payload AND s3 set (custom validation rejects)"
run "test_action_group_api_schema_both_payload_and_s3_rejected" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    action_group_definitions = {
      "bad" = {
        description = "x"
        lambda_arn  = "arn:aws:lambda:us-east-1:123456789012:function:bad"
        api_schema = {
          payload = "y"
          s3      = { s3_bucket_name = "b", s3_object_key = "k" }
        }
      }
    }
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  expect_failures = [var.action_group_definitions]
}

###############################################################################
# Validation Boundaries (boundary-pass cases) — verify accept-side
###############################################################################

# Scenario: "Validation Boundary - agent_name = \"a\" (length 1, regex pass) accepted"
run "test_agent_name_min_length_accepted" {
  command = plan

  variables {
    agent_name  = "a"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.agent_name == "a"
    error_message = "agent_name at minimum length (1 char) must be accepted."
  }
}

# Scenario: "Validation Boundary - agent_name 100-char string of [A-Za-z0-9_-] accepted"
run "test_agent_name_max_length_accepted" {
  command = plan

  variables {
    # 100 'a' characters
    agent_name  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.agent_name != ""
    error_message = "agent_name at maximum length (100 chars) must be accepted."
  }
}

# Scenario: "Validation Boundary - instruction 40-char string accepted (minimum)"
run "test_instruction_min_length_accepted" {
  command = plan

  variables {
    agent_name = "test"
    # 40 'a' characters
    instruction = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.agent_name != ""
    error_message = "instruction at minimum length (40 chars) must be accepted."
  }
}

# Scenario: "Validation Boundary - instruction 20000-char string accepted (maximum)"
run "test_instruction_max_length_accepted" {
  command = plan

  variables {
    agent_name = "test"
    # 20000 'a' characters
    instruction = join("", [for i in range(200) : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.agent_name != ""
    error_message = "instruction at maximum length (20000 chars) must be accepted."
  }
}

# Scenario: "Validation Boundary - idle_session_ttl_seconds = 60 accepted (minimum)"
run "test_idle_session_ttl_min_accepted" {
  command = plan

  variables {
    agent_name               = "test"
    instruction              = "This is a perfectly valid instruction string of forty plus characters."
    idle_session_ttl_seconds = 60
    environment              = "test"
    owner                    = "x@y.z"
    cost_center              = "c"
    project                  = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.idle_session_ttl_in_seconds == 60
    error_message = "idle_session_ttl_seconds at minimum (60) must be accepted."
  }
}

# Scenario: "Validation Boundary - idle_session_ttl_seconds = 3600 accepted (maximum)"
run "test_idle_session_ttl_max_accepted" {
  command = plan

  variables {
    agent_name               = "test"
    instruction              = "This is a perfectly valid instruction string of forty plus characters."
    idle_session_ttl_seconds = 3600
    environment              = "test"
    owner                    = "x@y.z"
    cost_center              = "c"
    project                  = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.idle_session_ttl_in_seconds == 3600
    error_message = "idle_session_ttl_seconds at maximum (3600) must be accepted."
  }
}

# Scenario: "Validation Boundary - log_retention_days = 1 accepted (smallest CloudWatch-allowed value)"
run "test_log_retention_days_min_accepted" {
  command = plan

  variables {
    agent_name         = "test"
    instruction        = "This is a perfectly valid instruction string of forty plus characters."
    log_retention_days = 1
    environment        = "test"
    owner              = "x@y.z"
    cost_center        = "c"
    project            = "p"
  }

  assert {
    condition     = aws_cloudwatch_log_group.agent.retention_in_days == 1
    error_message = "log_retention_days = 1 (smallest CloudWatch-allowed value) must be accepted."
  }
}

# Scenario: "Validation Boundary - log_retention_days = 90 accepted (default, mid-range)"
run "test_log_retention_days_default_accepted" {
  command = plan

  variables {
    agent_name         = "test"
    instruction        = "This is a perfectly valid instruction string of forty plus characters."
    log_retention_days = 90
    environment        = "test"
    owner              = "x@y.z"
    cost_center        = "c"
    project            = "p"
  }

  assert {
    condition     = aws_cloudwatch_log_group.agent.retention_in_days == 90
    error_message = "log_retention_days = 90 (default, mid-range) must be accepted."
  }
}

# Scenario: "Validation Boundary - log_retention_days = 3653 accepted (largest CloudWatch-allowed value)"
run "test_log_retention_days_max_accepted" {
  command = plan

  variables {
    agent_name         = "test"
    instruction        = "This is a perfectly valid instruction string of forty plus characters."
    log_retention_days = 3653
    environment        = "test"
    owner              = "x@y.z"
    cost_center        = "c"
    project            = "p"
  }

  assert {
    condition     = aws_cloudwatch_log_group.agent.retention_in_days == 3653
    error_message = "log_retention_days = 3653 (largest CloudWatch-allowed value) must be accepted."
  }
}

# Scenario: "Validation Boundary - wait_after_prepare_seconds = 0 accepted (disable timer)"
run "test_wait_after_prepare_zero_accepted" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    wait_after_prepare_seconds = 0
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  assert {
    condition     = time_sleep.wait_after_prepare.create_duration == "0s"
    error_message = "wait_after_prepare_seconds = 0 (disable timer) must be accepted."
  }
}

# Scenario: "Validation Boundary - wait_after_prepare_seconds = 120 accepted (maximum)"
run "test_wait_after_prepare_max_accepted" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    wait_after_prepare_seconds = 120
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  assert {
    condition     = time_sleep.wait_after_prepare.create_duration == "120s"
    error_message = "wait_after_prepare_seconds = 120 (maximum) must be accepted."
  }
}

# Scenario: "Validation Boundary - api_throttling_rate_limit = 1 accepted (smallest positive)"
run "test_api_throttling_rate_limit_min_accepted" {
  command = plan

  variables {
    agent_name                = "test"
    instruction               = "This is a perfectly valid instruction string of forty plus characters."
    enable_api_gateway        = true
    api_throttling_rate_limit = 1
    environment               = "test"
    owner                     = "x@y.z"
    cost_center               = "c"
    project                   = "p"
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_rate_limit == 1
    error_message = "api_throttling_rate_limit = 1 (smallest positive) must be accepted."
  }
}

# Scenario: "Validation Boundary - api_throttling_rate_limit = 10000 accepted (maximum)"
run "test_api_throttling_rate_limit_max_accepted" {
  command = plan

  variables {
    agent_name                = "test"
    instruction               = "This is a perfectly valid instruction string of forty plus characters."
    enable_api_gateway        = true
    api_throttling_rate_limit = 10000
    environment               = "test"
    owner                     = "x@y.z"
    cost_center               = "c"
    project                   = "p"
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_rate_limit == 10000
    error_message = "api_throttling_rate_limit = 10000 (maximum) must be accepted."
  }
}

# Scenario: "Validation Boundary - api_throttling_burst_limit = 1 accepted (smallest positive)"
run "test_api_throttling_burst_limit_min_accepted" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    enable_api_gateway         = true
    api_throttling_burst_limit = 1
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_burst_limit == 1
    error_message = "api_throttling_burst_limit = 1 (smallest positive) must be accepted."
  }
}

# Scenario: "Validation Boundary - api_throttling_burst_limit = 10000 accepted (maximum)"
run "test_api_throttling_burst_limit_max_accepted" {
  command = plan

  variables {
    agent_name                 = "test"
    instruction                = "This is a perfectly valid instruction string of forty plus characters."
    enable_api_gateway         = true
    api_throttling_burst_limit = 10000
    environment                = "test"
    owner                      = "x@y.z"
    cost_center                = "c"
    project                    = "p"
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_burst_limit == 10000
    error_message = "api_throttling_burst_limit = 10000 (maximum) must be accepted."
  }
}

# Scenario: "Validation Boundary - environment = \"sandbox\" accepted (one of the validation set)"
run "test_environment_sandbox_accepted" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    environment = "sandbox"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.tags["Environment"] == "sandbox"
    error_message = "environment = 'sandbox' (one of allowed values) must be accepted."
  }
}

# Scenario: "Validation Boundary - kms_key_arn = \"\" accepted (empty triggers module-created key)"
run "test_kms_key_arn_empty_accepted" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    kms_key_arn = ""
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "Empty kms_key_arn must be accepted and trigger module-created KMS key."
  }
}

# Scenario: "Validation Boundary - kms_key_arn GovCloud partition pattern accepted"
run "test_kms_key_arn_govcloud_partition_accepted" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "This is a perfectly valid instruction string of forty plus characters."
    kms_key_arn = "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/abcd"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.customer_encryption_key_arn == "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/abcd"
    error_message = "GovCloud partition KMS ARN must be accepted."
  }
}

# Scenario: "Validation Boundary - knowledge_base_s3_bucket_arn empty when enable_knowledge_base = false accepted"
run "test_knowledge_base_s3_bucket_arn_empty_when_kb_disabled_accepted" {
  command = plan

  variables {
    agent_name                   = "test"
    instruction                  = "This is a perfectly valid instruction string of forty plus characters."
    enable_knowledge_base        = false
    knowledge_base_s3_bucket_arn = ""
    environment                  = "test"
    owner                        = "x@y.z"
    cost_center                  = "c"
    project                      = "p"
  }

  assert {
    condition     = length(aws_bedrockagent_knowledge_base.this) == 0
    error_message = "Empty knowledge_base_s3_bucket_arn with KB disabled must be accepted with no KB resources."
  }
}

# Scenario: "Validation Boundary - guardrail_id = \"\" accepted (no guardrail bound)"
run "test_guardrail_id_empty_accepted" {
  command = plan

  variables {
    agent_name   = "test"
    instruction  = "This is a perfectly valid instruction string of forty plus characters."
    guardrail_id = ""
    environment  = "test"
    owner        = "x@y.z"
    cost_center  = "c"
    project      = "p"
  }

  assert {
    condition     = length(aws_bedrockagent_agent.this.guardrail_configuration) == 0
    error_message = "Empty guardrail_id must be accepted with no guardrail block on the agent."
  }
}

# Scenario: "Validation Boundary - guardrail_version = \"DRAFT\" with guardrail_id != \"\" accepted"
run "test_guardrail_version_draft_accepted" {
  command = plan

  variables {
    agent_name        = "test"
    instruction       = "This is a perfectly valid instruction string of forty plus characters."
    guardrail_id      = "abc123"
    guardrail_version = "DRAFT"
    environment       = "test"
    owner             = "x@y.z"
    cost_center       = "c"
    project           = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "DRAFT"
    error_message = "guardrail_version = 'DRAFT' must be accepted (with documentation warning)."
  }
}

# Scenario: "Validation Boundary - guardrail_version = \"42\" with guardrail_id != \"\" accepted"
run "test_guardrail_version_numeric_accepted" {
  command = plan

  variables {
    agent_name        = "test"
    instruction       = "This is a perfectly valid instruction string of forty plus characters."
    guardrail_id      = "abc123"
    guardrail_version = "42"
    environment       = "test"
    owner             = "x@y.z"
    cost_center       = "c"
    project           = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "42"
    error_message = "Numeric guardrail_version (e.g., '42') must be accepted."
  }
}
