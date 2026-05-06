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

# Scenario: "Full Features (complete)"
run "test_full_features" {
  command = plan

  variables {
    agent_name               = "test-agent-full"
    instruction              = "You are a helpful assistant. Use available tools to answer user queries. Use the knowledge base when the user asks about company-specific topics. Use the code interpreter for computational tasks."
    foundation_model         = "anthropic.claude-sonnet-4-20250514"
    agent_alias_name         = "prod"
    idle_session_ttl_seconds = 1800
    enable_code_interpreter  = true
    action_group_definitions = {
      "weather-tool" = {
        description = "Look up the weather for a city."
        lambda_arn  = "arn:aws:lambda:us-east-1:123456789012:function:weather"
        function_schema = {
          functions = [{
            name        = "get_weather"
            description = "Returns current weather for a city"
            parameters = {
              city = { type = "string", description = "City name", required = true }
            }
          }]
        }
      }
      "calendar-tool" = {
        description = "Manage calendar events."
        lambda_arn  = "arn:aws:lambda:us-east-1:123456789012:function:calendar"
        api_schema  = { payload = "openapi: 3.0.0\ninfo:\n  title: Calendar\n  version: 1.0.0\npaths: {}" }
      }
    }
    enable_knowledge_base        = true
    knowledge_base_s3_bucket_arn = "arn:aws:s3:::test-corpus-bucket"
    # AWS Bedrock data source inclusion_prefixes is fixed-length 1 (set must contain
    # at most 1 element); use a single prefix here. Multi-prefix coverage is exercised
    # via aggregated patterns when needed.
    knowledge_base_inclusion_prefixes = ["docs/"]
    knowledge_base_description        = "Use this KB when the user asks about company policy."
    enable_api_gateway                = true
    api_throttling_rate_limit         = 500
    api_throttling_burst_limit        = 1000
    guardrail_id                      = "abc123def456"
    guardrail_version                 = "1"
    log_retention_days                = 365
    force_destroy                     = true
    environment                       = "prod"
    owner                             = "team-genai@example.com"
    cost_center                       = "cc-1234"
    project                           = "agentcore-tests"
    tags                              = { Workload = "agent-platform" }
  }

  assert {
    condition     = length(aws_bedrockagent_agent_action_group.lambda) == 2
    error_message = "Two Lambda action groups must be created from the action_group_definitions map."
  }

  assert {
    condition     = length(aws_bedrockagent_agent_action_group.lambda["weather-tool"].function_schema[0].member_functions[0].functions) == 1
    error_message = "Weather tool must have function_schema with exactly one function."
  }

  assert {
    condition     = aws_bedrockagent_agent_action_group.lambda["weather-tool"].function_schema[0].member_functions[0].functions[0].name == "get_weather"
    error_message = "Weather tool function name must be 'get_weather'."
  }

  # [plan-unknown] api_schema[0].payload is the consumer-supplied string but propagates through the resource — substitute existence check
  assert {
    condition     = length(aws_bedrockagent_agent_action_group.lambda["calendar-tool"].api_schema) == 1
    error_message = "Calendar tool must use inline api_schema payload."
  }

  assert {
    condition     = aws_bedrockagent_agent_action_group.lambda["weather-tool"].action_group_executor[0].lambda == "arn:aws:lambda:us-east-1:123456789012:function:weather"
    error_message = "Weather tool action_group_executor.lambda must point at the supplied Lambda ARN."
  }

  assert {
    condition     = length(aws_lambda_permission.bedrock_invoke) == 2
    error_message = "One Lambda permission must be created per action group (2 expected)."
  }

  assert {
    condition     = aws_lambda_permission.bedrock_invoke["weather-tool"].principal == "bedrock.amazonaws.com"
    error_message = "Lambda permission principal must be bedrock.amazonaws.com."
  }

  assert {
    condition     = aws_lambda_permission.bedrock_invoke["weather-tool"].action == "lambda:InvokeFunction"
    error_message = "Lambda permission action must be lambda:InvokeFunction."
  }

  assert {
    condition     = length(aws_bedrockagent_knowledge_base.this) == 1
    error_message = "Knowledge base resource must be created when enable_knowledge_base = true."
  }

  assert {
    condition     = aws_bedrockagent_knowledge_base.this[0].knowledge_base_configuration[0].type == "VECTOR"
    error_message = "Knowledge base type must be VECTOR."
  }

  assert {
    condition     = aws_bedrockagent_knowledge_base.this[0].knowledge_base_configuration[0].vector_knowledge_base_configuration[0].embedding_model_configuration[0].bedrock_embedding_model_configuration[0].dimensions == 1024
    error_message = "Knowledge base embedding dimensions must be 1024 (Titan v2 default)."
  }

  assert {
    condition     = aws_bedrockagent_knowledge_base.this[0].storage_configuration[0].type == "OPENSEARCH_SERVERLESS"
    error_message = "Knowledge base storage type must be OPENSEARCH_SERVERLESS."
  }

  assert {
    condition     = aws_opensearchserverless_collection.kb[0].type == "VECTORSEARCH"
    error_message = "AOSS collection type must be VECTORSEARCH for KB use."
  }

  assert {
    condition     = length(aws_opensearchserverless_security_policy.encryption) == 1 && length(aws_opensearchserverless_security_policy.network) == 1
    error_message = "Both AOSS encryption and network security policies must be created."
  }

  assert {
    condition     = length(aws_opensearchserverless_access_policy.kb) == 1
    error_message = "AOSS data access policy must be created for the KB role."
  }

  assert {
    condition     = aws_bedrockagent_data_source.this[0].data_source_configuration[0].s3_configuration[0].bucket_arn == "arn:aws:s3:::test-corpus-bucket"
    error_message = "KB S3 data source bucket ARN must equal the consumer-supplied knowledge_base_s3_bucket_arn."
  }

  assert {
    condition     = aws_bedrockagent_data_source.this[0].vector_ingestion_configuration[0].chunking_configuration[0].chunking_strategy == "FIXED_SIZE"
    error_message = "KB chunking strategy must be FIXED_SIZE."
  }

  assert {
    condition     = aws_bedrockagent_data_source.this[0].data_deletion_policy == "RETAIN"
    error_message = "KB data deletion policy must be RETAIN to preserve the corpus when the data source is destroyed."
  }

  assert {
    condition     = length(aws_bedrockagent_agent_knowledge_base_association.this) == 1
    error_message = "KB-to-agent association must be created when KB is enabled."
  }

  assert {
    condition     = aws_bedrockagent_agent_knowledge_base_association.this[0].description == "Use this KB when the user asks about company policy."
    error_message = "KB association description must equal the input knowledge_base_description."
  }

  assert {
    condition     = aws_bedrockagent_agent_knowledge_base_association.this[0].agent_version == "DRAFT"
    error_message = "KB association must target agent_version DRAFT."
  }

  assert {
    condition     = length(time_sleep.wait_aoss_dap) == 1 && time_sleep.wait_aoss_dap[0].create_duration == "60s"
    error_message = "AOSS data-access-policy wait timer must be 60s."
  }

  assert {
    condition     = aws_apigatewayv2_api.this[0].protocol_type == "HTTP"
    error_message = "API Gateway protocol type must be HTTP (v2)."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].auto_deploy == true
    error_message = "API stage auto_deploy must be true."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].name == "$default"
    error_message = "API stage name must be $default."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_rate_limit == 500
    error_message = "API stage throttling rate limit must be applied from input (500)."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_burst_limit == 1000
    error_message = "API stage throttling burst limit must be applied from input (1000)."
  }

  # [plan-unknown] destination_arn references the log group ARN (computed) — substitute existence check
  assert {
    condition     = length(aws_apigatewayv2_stage.default[0].access_log_settings) >= 1
    error_message = "API stage access logging must be configured against the module log group."
  }

  assert {
    condition     = aws_apigatewayv2_integration.lambda[0].integration_type == "AWS_PROXY"
    error_message = "API integration type must be AWS_PROXY."
  }

  assert {
    condition     = aws_apigatewayv2_integration.lambda[0].payload_format_version == "2.0"
    error_message = "API integration payload format version must be 2.0."
  }

  assert {
    condition     = aws_apigatewayv2_integration.lambda[0].timeout_milliseconds == 30000
    error_message = "API integration timeout must be 30000ms (HTTP API hard cap)."
  }

  assert {
    condition     = aws_apigatewayv2_route.invoke[0].authorization_type == "NONE"
    error_message = "API route must be unauthenticated by default (consumer attaches their own authorizer)."
  }

  assert {
    condition     = aws_apigatewayv2_route.invoke[0].route_key == "POST /invoke"
    error_message = "API route key must be 'POST /invoke'."
  }

  assert {
    condition     = aws_lambda_function.invoker[0].runtime == "python3.12"
    error_message = "Invoker Lambda runtime must be python3.12."
  }

  assert {
    condition     = aws_lambda_function.invoker[0].tracing_config[0].mode == "Active"
    error_message = "Invoker Lambda must have X-Ray Active tracing enabled."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.lambda) == 1
    error_message = "Invoker Lambda log group must be created when API GW is enabled."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.apigw_access) == 1
    error_message = "API Gateway access log group must be created when API GW is enabled."
  }

  assert {
    condition     = aws_cloudwatch_log_group.agent.retention_in_days == 365
    error_message = "Agent log group must use the configured 365-day retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.lambda[0].retention_in_days == 365
    error_message = "Lambda log group must use the configured 365-day retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.apigw_access[0].retention_in_days == 365
    error_message = "API access log group must use the configured 365-day retention."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_identifier == "abc123def456"
    error_message = "Guardrail identifier must be bound to the agent."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "1"
    error_message = "Guardrail version must be pinned to the supplied numeric version (1)."
  }

  assert {
    condition     = aws_bedrockagent_agent_action_group.lambda["weather-tool"].skip_resource_in_use_check == true
    error_message = "force_destroy must propagate to action groups via skip_resource_in_use_check = true."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.tags["Workload"] == "agent-platform"
    error_message = "Custom Workload tag from var.tags must be merged into resource tags."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.tags["Environment"] == "prod"
    error_message = "Required Environment tag (prod) must still be present after merging custom tags."
  }

  assert {
    condition     = aws_bedrockagent_agent.this.idle_session_ttl_in_seconds == 1800
    error_message = "Agent idle_session_ttl_in_seconds must equal the supplied 1800."
  }

  assert {
    condition     = aws_bedrockagent_agent_alias.this.agent_alias_name == "prod"
    error_message = "Agent alias name must be 'prod' as supplied."
  }
}
