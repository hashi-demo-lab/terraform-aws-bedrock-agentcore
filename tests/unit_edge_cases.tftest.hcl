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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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

# Scenario: "Feature Interactions - Code interpreter disabled"
run "test_code_interpreter_disabled" {
  command = plan

  variables {
    agent_name              = "test"
    instruction             = "<minimum-40-char instruction string used here for validation>"
    enable_code_interpreter = false
    environment             = "test"
    owner                   = "x@y.z"
    cost_center             = "c"
    project                 = "p"
  }

  assert {
    condition     = length(aws_bedrockagent_agent_action_group.code_interpreter) == 0
    error_message = "Code interpreter action group must NOT be created when enable_code_interpreter = false."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.agent_name == "test"
    error_message = "Agent must still be created when code interpreter is disabled."
  }

  assert {
    condition     = time_sleep.wait_after_prepare.create_duration == "10s"
    error_message = "Time sleep dependency for prepare must remain at the default 10s."
  }
}

# Scenario: "Feature Interactions - Lambda action groups without code interpreter"
run "test_lambda_action_groups_without_code_interpreter" {
  command = plan

  variables {
    agent_name              = "test"
    instruction             = "<minimum-40-char instruction string used here for validation>"
    enable_code_interpreter = false
    action_group_definitions = {
      "only-tool" = {
        description = "Only tool"
        lambda_arn  = "arn:aws:lambda:us-east-1:123456789012:function:only"
        function_schema = {
          functions = [{ name = "do_thing", description = "Do it", parameters = {} }]
        }
      }
    }
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = length(aws_bedrockagent_agent_action_group.lambda) == 1 && length(aws_bedrockagent_agent_action_group.code_interpreter) == 0
    error_message = "Exactly one Lambda action group should exist with no code interpreter action group."
  }

  assert {
    condition     = length(aws_lambda_permission.bedrock_invoke) == 1
    error_message = "Lambda permission must be created for the single Lambda action group."
  }
}

# Scenario: "Feature Interactions - API Gateway enabled without knowledge base"
run "test_api_gateway_without_knowledge_base" {
  command = plan

  variables {
    agent_name            = "test"
    instruction           = "<minimum-40-char instruction string used here for validation>"
    enable_api_gateway    = true
    enable_knowledge_base = false
    environment           = "test"
    owner                 = "x@y.z"
    cost_center           = "c"
    project               = "p"
  }

  assert {
    condition     = length(aws_apigatewayv2_api.this) == 1
    error_message = "API Gateway HTTP API must be created when enable_api_gateway = true."
  }

  assert {
    condition     = length(aws_lambda_function.invoker) == 1
    error_message = "Invoker Lambda must be created when API Gateway is enabled."
  }

  assert {
    condition     = length(aws_bedrockagent_knowledge_base.this) == 0 && length(aws_opensearchserverless_collection.kb) == 0
    error_message = "Knowledge-base side resources (KB + AOSS collection) must NOT be created when KB is disabled."
  }

  assert {
    condition     = length(aws_bedrockagent_agent_knowledge_base_association.this) == 0
    error_message = "KB-to-agent association must NOT be created when KB is disabled."
  }
}

# Scenario: "Feature Interactions - Knowledge base enabled without API Gateway"
run "test_knowledge_base_without_api_gateway" {
  command = plan

  variables {
    agent_name                   = "test"
    instruction                  = "<minimum-40-char instruction string used here for validation>"
    enable_knowledge_base        = true
    knowledge_base_s3_bucket_arn = "arn:aws:s3:::corpus"
    enable_api_gateway           = false
    environment                  = "test"
    owner                        = "x@y.z"
    cost_center                  = "c"
    project                      = "p"
  }

  assert {
    condition     = length(aws_bedrockagent_knowledge_base.this) == 1
    error_message = "Knowledge base must be created when enable_knowledge_base = true."
  }

  assert {
    condition     = length(aws_bedrockagent_agent_knowledge_base_association.this) == 1
    error_message = "KB-to-agent association must be created."
  }

  assert {
    condition     = length(time_sleep.wait_aoss_dap) == 1
    error_message = "AOSS data-access-policy wait timer must be present."
  }

  assert {
    condition     = length(aws_apigatewayv2_api.this) == 0
    error_message = "API Gateway resources must NOT be created when API Gateway is disabled."
  }

  assert {
    condition     = length(aws_lambda_function.invoker) == 0
    error_message = "Invoker Lambda must NOT be created when API Gateway is disabled."
  }
}

# Scenario: "Feature Interactions - Bring-your-own KMS key"
run "test_byo_kms_key" {
  command = plan

  variables {
    agent_name  = "test"
    instruction = "<minimum-40-char instruction string used here for validation>"
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    environment = "test"
    owner       = "x@y.z"
    cost_center = "c"
    project     = "p"
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "Module-created KMS key must NOT be present when var.kms_key_arn is provided."
  }

  assert {
    condition     = length(aws_kms_alias.this) == 0
    error_message = "Module-created KMS alias must NOT be present when var.kms_key_arn is provided."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.customer_encryption_key_arn == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "Agent must use the bring-your-own KMS key ARN."
  }

  assert {
    condition     = aws_cloudwatch_log_group.agent.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "Agent log group must be encrypted with the bring-your-own KMS key."
  }
}

# Scenario: "Feature Interactions - Guardrail bound without enabling other features"
run "test_guardrail_only" {
  command = plan

  variables {
    agent_name        = "test"
    instruction       = "<minimum-40-char instruction string used here for validation>"
    guardrail_id      = "gd123abc"
    guardrail_version = "2"
    environment       = "test"
    owner             = "x@y.z"
    cost_center       = "c"
    project           = "p"
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_identifier == "gd123abc"
    error_message = "Guardrail identifier block must be populated on the agent."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "2"
    error_message = "Guardrail version must be pinned to the supplied value (2)."
  }

  assert {
    condition     = length(regexall("bedrock:ApplyGuardrail", aws_iam_role_policy.agent.policy)) > 0
    error_message = "Agent inline policy must include a bedrock:ApplyGuardrail statement when a guardrail is bound."
  }
}
