###############################################################################
# api_gateway.tf — Item F
#
# All resources gated on `var.enable_api_gateway ? 1 : 0`. Split out of main.tf
# to honor the constitution §2.1 file-size cap (500 lines).
#
# Topology:
#   client -> aws_apigatewayv2_api (HTTP, $default stage with throttle + JSON
#             access logs) -> aws_apigatewayv2_route POST /invoke ->
#             aws_apigatewayv2_integration (AWS_PROXY, payload v2.0) ->
#             aws_lambda_function.invoker (Python 3.12, X-Ray Active) ->
#             bedrock-agent-runtime:InvokeAgent against the alias.
#
# Authorization is intentionally NONE on the route — consumers attach their
# own JWT/Lambda/IAM authorizer using the api_id / default_route_key /
# api_execution_arn outputs (see design.md §2 + research-bedrock-api-gateway.md).
#
# Schema notes (verified via provider docs):
#   - aws_apigatewayv2_stage.default_route_settings is list-typed `[0]`.
#   - aws_apigatewayv2_stage.access_log_settings is list-typed `[0]`.
#   - aws_apigatewayv2_stage.route_settings (per-route override) is set-typed —
#     not used here, but design.md §5 calls out one() for downstream tests.
#   - aws_lambda_function.tracing_config + environment + vpc_config are all
#     list-typed `[0]`.
#   - aws_apigatewayv2_api.cors_configuration is list-typed (max_items = 1)
#     with allow_credentials, allow_headers, allow_methods, allow_origins,
#     expose_headers, max_age sub-fields. Wired via dynamic block driven by
#     `var.cors_configuration != null`.
###############################################################################

# Lambda execution role for the invoker. Trust policy is in
# data.aws_iam_policy_document.lambda_assume — standard lambda.amazonaws.com.
resource "aws_iam_role" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name               = "${var.agent_name}-invoker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name   = "${var.agent_name}-invoker-inline"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda_inline[0].json
}

# Dedicated invoker Lambda log group — KMS-encrypted with the resolved CMK
# and configurable retention. Created BEFORE the function so its ARN is
# resolvable for the inline policy and the function's implicit logging path.
resource "aws_cloudwatch_log_group" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  name              = "/aws/lambda/${var.agent_name}-invoker"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn_resolved

  tags = local.tags
}

# Bundled invoker Lambda. Source is the zipped files/invoker/ directory; the
# source_code_hash drives in-place updates on .py changes. Environment is
# encrypted at rest with the same CMK as the agent + log groups (kms_key_arn).
# X-Ray Active tracing is mandatory per the security baseline.
resource "aws_lambda_function" "invoker" {
  count = var.enable_api_gateway ? 1 : 0

  function_name    = "${var.agent_name}-invoker"
  role             = aws_iam_role.lambda[0].arn
  filename         = data.archive_file.invoker_zip[0].output_path
  source_code_hash = data.archive_file.invoker_zip[0].output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = local.kms_key_arn_resolved

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      AGENT_ID       = aws_bedrockagent_agent.this.agent_id
      AGENT_ALIAS_ID = aws_bedrockagent_agent_alias.this.agent_alias_id
    }
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

# HTTP API (v2). Protocol HTTP, no built-in authorizer — consumers attach
# their own. CORS is opt-in via var.cors_configuration: when non-null the
# dynamic block below emits a `cors_configuration` block on the API resource
# with the consumer-supplied allow_origins / allow_methods / allow_headers /
# max_age. allow_credentials and expose_headers are not exposed in v1; if
# needed they can be added to the variable type + this block in a follow-up.
resource "aws_apigatewayv2_api" "this" {
  count = var.enable_api_gateway ? 1 : 0

  name          = "${var.agent_name}-api"
  protocol_type = "HTTP"
  description   = "HTTP API for Bedrock agent ${var.agent_name}."

  dynamic "cors_configuration" {
    for_each = var.cors_configuration != null ? [var.cors_configuration] : []
    content {
      allow_origins = cors_configuration.value.allow_origins
      allow_methods = cors_configuration.value.allow_methods
      allow_headers = cors_configuration.value.allow_headers
      max_age       = cors_configuration.value.max_age
    }
  }

  tags = local.tags
}

# AWS_PROXY integration -> invoker Lambda. payload_format_version = "2.0" is
# required for HTTP API + Lambda proxy; timeout is hard-capped at 30000ms by
# the HTTP API service quota.
resource "aws_apigatewayv2_integration" "lambda" {
  count = var.enable_api_gateway ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.invoker[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

# Single default route. authorization_type defaults to NONE — the design
# explicitly defers auth attachment to the consumer.
resource "aws_apigatewayv2_route" "invoke" {
  count = var.enable_api_gateway ? 1 : 0

  api_id             = aws_apigatewayv2_api.this[0].id
  route_key          = "POST /invoke"
  target             = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
  authorization_type = "NONE"
}

# API Gateway access log group — separate from the Lambda log group so
# retention/encryption can be tuned independently. Same CMK + retention defaults.
resource "aws_cloudwatch_log_group" "apigw_access" {
  count = var.enable_api_gateway ? 1 : 0

  name              = "/aws/apigateway/${var.agent_name}-access"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn_resolved

  tags = local.tags
}

# $default stage with auto_deploy. default_route_settings carries the throttle
# limits (per-stage default applied to all routes); access_log_settings emits a
# structured JSON record per request to the dedicated log group above.
resource "aws_apigatewayv2_stage" "default" {
  count = var.enable_api_gateway ? 1 : 0

  api_id      = aws_apigatewayv2_api.this[0].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttling_rate_limit
    throttling_burst_limit = var.api_throttling_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_access[0].arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = local.tags
}

# Resource-policy permission allowing the API Gateway service principal to
# invoke the function. source_arn pinned to this API + any stage + any route.
resource "aws_lambda_permission" "apigw_invoke" {
  count = var.enable_api_gateway ? 1 : 0

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.invoker[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this[0].execution_arn}/*/*"
}
