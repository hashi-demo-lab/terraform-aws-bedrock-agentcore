## Research: Architectural pattern for OPTIONAL HTTP exposure of a Bedrock agent via API Gateway v2

### Decision

When `enable_api_gateway = true`, the module provisions an HTTP API (API Gateway v2) that proxies to a small purpose-built invoker Lambda, which calls `bedrock-agent-runtime:InvokeAgent` against the configured agent alias. The module owns the API, default stage, integration, route, throttling defaults (rate 100 rps / burst 200), an access-log CloudWatch log group (KMS-encrypted when a key is supplied), and the invoker Lambda + execution role. The module deliberately does NOT create an authorizer; it exposes `api_id`, `api_endpoint`, `route_key`, `stage_name`, and `execution_arn` outputs so consumers can attach `aws_apigatewayv2_authorizer` and `aws_apigatewayv2_route` overrides themselves. CORS defaults to disabled. Usage plans are intentionally not configured (HTTP API does not support them).

### Resources Identified

- **Primary Resource**: `aws_apigatewayv2_api` — HTTP API fronting the Bedrock invoker Lambda
- **Supporting Resources**:
  - `aws_apigatewayv2_integration` — `AWS_PROXY` integration (`integration_type = "AWS_PROXY"`, `integration_uri = aws_lambda_function.invoker.invoke_arn`, `payload_format_version = "2.0"`)
  - `aws_apigatewayv2_route` — default route (e.g. `POST /invoke`) wired to the integration; `authorization_type` defaults to `NONE` and is overridable via input
  - `aws_apigatewayv2_stage` — `$default` auto-deploy stage with `default_route_settings` (throttle), `access_log_settings`, and `auto_deploy = true`
  - `aws_lambda_function` — invoker (Python 3.12 / Node.js 20.x runtime), short timeout-tolerant (90s+) for streaming/non-streaming agent responses
  - `aws_lambda_permission` — grants `apigateway.amazonaws.com` the right to invoke the function with `source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/*"`
  - `aws_iam_role` + `aws_iam_role_policy` (or `aws_iam_policy` + attachment) — Lambda execution role with `bedrock:InvokeAgent` scoped to the agent alias ARN, plus `AWSLambdaBasicExecutionRole` managed policy (or inline equivalent CloudWatch Logs perms)
  - `aws_cloudwatch_log_group` (x2) — one for the invoker Lambda (`/aws/lambda/<fn-name>`), one for API GW access logs (`/aws/apigateway/<api-name>/access-logs`); both tagged, retention configurable, optional `kms_key_id`
- **Key Arguments** (HTTP API stage):
  - `aws_apigatewayv2_api.protocol_type = "HTTP"`
  - `aws_apigatewayv2_stage.default_route_settings { throttling_rate_limit = 100, throttling_burst_limit = 200 }`
  - `aws_apigatewayv2_stage.access_log_settings { destination_arn = <log group arn>, format = <JSON format string> }`
  - `aws_apigatewayv2_stage.auto_deploy = true`
  - `aws_apigatewayv2_integration.payload_format_version = "2.0"` (required for HTTP API + Lambda proxy)
  - `aws_apigatewayv2_integration.timeout_milliseconds` — max 30000 ms for HTTP API (hard service quota)
- **Key Outputs**:
  - `api_id` (`string`) — for consumer-attached authorizers/routes
  - `api_endpoint` (`string`) — the invoke URL (`https://<id>.execute-api.<region>.amazonaws.com`)
  - `api_arn` (`string`) — for resource policies / WAF associations
  - `api_execution_arn` (`string`) — needed for `aws_lambda_permission.source_arn` if consumer adds more integrations
  - `default_route_key` (`string`) — e.g. `"POST /invoke"`, so consumers can override `authorization_type`
  - `stage_name` (`string`) — `"$default"`
  - `invoker_lambda_arn` (`string`), `invoker_lambda_name` (`string`), `invoker_lambda_role_arn` (`string`)
  - `access_log_group_name` (`string`), `access_log_group_arn` (`string`)
- **Security Considerations**:
  - Access logs MUST be on; default the log format to a structured JSON template that includes `requestId`, `ip`, `requestTime`, `httpMethod`, `routeKey`, `status`, `protocol`, `responseLength`, `integrationErrorMessage`, `authorizer.error`
  - CloudWatch log group encryption with optional customer-managed KMS key (input `log_kms_key_arn`); separate log groups for Lambda vs access logs so retention/encryption can be tuned independently
  - Lambda execution role uses least-privilege `bedrock:InvokeAgent` scoped to the specific agent alias ARN, NOT `*`
  - `authorization_type` on the route defaults to `NONE` only because the consumer is contractually responsible — document this prominently and fail loudly in examples; optionally accept `authorizer_id` + `authorization_type` inputs to wire a consumer-built authorizer in-module
  - CORS disabled by default (`cors_configuration` block omitted); consumers opt-in
  - Recommend (but do not force) WAFv2 web ACL association via output of `api_arn`

### Rationale

**1. Why API Gateway v2 (HTTP API) → Lambda → `bedrock-agent-runtime:InvokeAgent`**

Amazon Bedrock Agents have no native HTTPS endpoint. The published AWS pattern (AWS Machine Learning Blog: "Build generative AI agents with Amazon Bedrock, Amazon DynamoDB, Amazon Lambda, Amazon Lex, and Amazon CloudWatch") and the Bedrock Agent Runtime API reference both show clients invoking the agent through the AWS SDK using `InvokeAgent` (or `InvokeInlineAgent`), which is a sigv4-signed AWS API call — not an HTTP endpoint suitable for direct browser/mobile consumption. To expose it over HTTP, AWS reference architectures uniformly place a thin Lambda between API Gateway and Bedrock to perform the SDK call, manage session IDs, and stream/aggregate the response chunks. HTTP API (v2) is preferred over REST API (v1) because it is roughly 70% cheaper, supports JWT/Lambda authorizers natively, and has lower latency — at the cost of features (usage plans, request/response transformations, edge-optimized endpoints) we do not need here.

**2. Why a thin invoker Lambda is part of the module**

The Bedrock agent has no HTTP frontend and `InvokeAgent` returns a streaming `EventStream` of completion chunks. Consumers expect a synchronous JSON response from API Gateway. Without the invoker Lambda the consumer must always supply one, defeating the convenience of `enable_api_gateway`. Bundling a minimal default invoker (Python 3.12, ~80 LOC) keeps the module self-contained while still allowing override via `invoker_lambda_source_path` / `invoker_lambda_image_uri` inputs. The Lambda also isolates agent-runtime SDK version pinning from the consumer.

**3. Why the authorizer stays a consumer concern**

Authorization is environment-specific (Cognito user pool ARN, custom JWT issuer URL, IAM principals, internal Lambda authorizer code) and changes more often than the API surface. Hardcoding any choice forces consumers into rework. The idiomatic pattern (matches `terraform-aws-modules/apigateway-v2/aws`) is: module creates `aws_apigatewayv2_api`, `aws_apigatewayv2_stage`, integration, and a default unauthenticated route; exposes `api_id`, `default_route_key`, `execution_arn`. Consumers then attach `aws_apigatewayv2_authorizer` + `aws_apigatewayv2_route` overrides with `authorization_type = "JWT"` or `"CUSTOM"`. We additionally accept optional inputs `authorizer_id` (string) and `authorization_type` (string, default `"NONE"`) so that consumers who want a one-shot wiring can pass values in, but we do not create the authorizer ourselves.

**4. IAM scope for the invoker Lambda**

Per the Bedrock Agent Runtime IAM reference, `bedrock:InvokeAgent` accepts a resource ARN of the form `arn:aws:bedrock:<region>:<account>:agent-alias/<agent-id>/<alias-id>`. The execution role policy is:

```hcl
statement {
  sid       = "InvokeBedrockAgentAlias"
  effect    = "Allow"
  actions   = ["bedrock:InvokeAgent"]
  resources = [var.agent_alias_arn]
}
```

Plus the standard `AWSLambdaBasicExecutionRole` managed policy (or an inline equivalent granting `logs:CreateLogStream` and `logs:PutLogEvents` on the function's log group ARN). If the agent uses a customer-managed KMS key for session encryption, add `kms:Decrypt` and `kms:GenerateDataKey` on the key ARN. If the consumer enables X-Ray, add `AWSXRayDaemonWriteAccess`.

**5. CloudWatch log groups**

Per the AWS API Gateway documentation ("Set up CloudWatch logging for HTTP APIs"), access logging is configured via the stage's `access_log_settings` and the log group MUST be in the same region. Best practice is a dedicated log group per API per stage, distinct from the Lambda's own `/aws/lambda/<name>` log group, because:
- Retention and KMS settings often differ (access logs are higher-volume, frequently archived to S3)
- Log group ARNs become resource-policy targets (e.g. for log subscription filters to a SIEM)
- Mixing application logs with edge/access logs hurts queryability in CloudWatch Logs Insights

Both groups should accept `var.log_kms_key_arn` (optional) and `var.log_retention_days` (default `30`).

**6. HTTP API throttling specifics**

`aws_apigatewayv2_stage.default_route_settings` accepts `throttling_rate_limit` (steady-state RPS) and `throttling_burst_limit` (token bucket size). These are PER-STAGE defaults applied to all routes; per-route overrides go in `route_settings` blocks keyed by route_key. Defaults of 100 RPS / 200 burst align with Bedrock agent's own concurrency posture and protect the downstream invoker Lambda from runaway request floods. These are not a substitute for WAF rate-based rules — document that.

**7. Edge cases confirmed**

- **Usage plans / API keys**: `aws_api_gateway_usage_plan` is a v1 (REST API) resource only. HTTP API has no concept of usage plans. Consumers needing per-customer quotas must either use Lambda authorizer + DynamoDB counters or move to REST API. Document this in the variable description for `enable_api_gateway`.
- **CORS**: `aws_apigatewayv2_api.cors_configuration` is omitted by default. If we set it, browser preflight is handled by API Gateway without invoking the Lambda. Recommend exposing a `cors_configuration` variable (object with `allow_origins`, `allow_methods`, `allow_headers`, `max_age`) defaulting to `null` (disabled). This keeps the module flexible without leaking a default that may be wrong (`*` is a security smell).
- **Integration timeout ceiling**: HTTP API integrations are hard-capped at 30000 ms per request. Bedrock agents with long tool-use chains can exceed this. For longer responses, consumers must use Lambda Function URL with response streaming or an async pattern (SQS + WebSocket). Document in the README.
- **Payload format**: HTTP API + Lambda proxy requires `payload_format_version = "2.0"`. The invoker Lambda must parse `event["body"]` (string, possibly base64) and return `{"statusCode": 200, "body": json.dumps(...), "headers": {...}}`.
- **Auto-deploy `$default` stage**: Using `auto_deploy = true` on the `$default` stage avoids needing a separate `aws_apigatewayv2_deployment` resource and is the idiomatic HTTP API pattern.

**8. Public registry patterns studied**

- `terraform-aws-modules/apigateway-v2/aws` (HashiCorp-curated, >2M downloads): exposes `api_id`, `api_endpoint`, `default_apigatewayv2_stage_id`, `default_apigatewayv2_stage_execution_arn`; lets routes/authorizers/integrations be passed in via map variables. Confirms the "expose IDs, let consumer attach authorizers" pattern. We adopt the output shape but do NOT adopt the giant map-of-routes input (over-engineered for a single-purpose module).
- `terraform-aws-modules/lambda/aws`: confirms execution role + log group + permission shape. We do not depend on it (keeps the module's dependency surface small) but mirror its variable naming (`function_name`, `runtime`, `handler`, `timeout`, `memory_size`).
- AWS Solutions Library / `aws-samples/amazon-bedrock-samples`: the "Bedrock agent + API Gateway" reference architecture matches the API GW v2 -> Lambda -> InvokeAgent topology described above and is the most direct precedent.

### Alternatives Considered

| Alternative | Why Not |
| ----------- | ------- |
| REST API (`aws_api_gateway_rest_api`, v1) | Higher cost, higher latency, no JWT authorizer support; only justified if usage plans / API keys / request-response transforms are required, which the current scope does not need |
| API Gateway direct AWS service integration to `bedrock-agent-runtime:InvokeAgent` (no Lambda) | HTTP API does not support arbitrary AWS service integrations the way REST API does; even on REST, `InvokeAgent` returns a streaming `EventStream` that API Gateway cannot translate to a synchronous JSON response without a Lambda transformer |
| Lambda Function URL instead of API Gateway | Loses pluggable authorizer ecosystem (only IAM or NONE), no built-in throttling per-route, no native access log format, no WAFv2 association. Acceptable for prototypes, not for the "HTTP exposure" feature consumers expect |
| AppSync GraphQL frontend | Heavier surface; consumers asking for "HTTP" expect REST/JSON, not GraphQL; misaligned with feature flag name `enable_api_gateway` |
| Bake in a Cognito JWT authorizer by default | Forces every consumer to either accept Cognito or rip out the authorizer; violates "authorization is consumer concern" principle |
| Single shared CloudWatch log group for Lambda + access logs | Hurts retention/encryption tuning, makes Logs Insights queries noisier, violates AWS Well-Architected logging guidance |
| Provision a usage plan + API key | Not supported on HTTP API; would silently fail or force a switch to REST API |
| Default `cors_configuration` to `allow_origins = ["*"]` | Security smell; encourages copy-paste insecurity. Default to `null` (disabled), let consumer opt in |
| Skip the invoker Lambda and require consumer to BYO | Defeats the purpose of `enable_api_gateway` as a one-flag convenience; consumers without Lambda expertise cannot use the feature |

### Sources

- AWS docs — Amazon Bedrock Agents: https://docs.aws.amazon.com/bedrock/latest/userguide/agents.html
- AWS docs — Bedrock Agent Runtime `InvokeAgent`: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_InvokeAgent.html
- AWS docs — IAM permissions for Bedrock Agents (resource ARN format `agent-alias/<agent-id>/<alias-id>`): https://docs.aws.amazon.com/bedrock/latest/userguide/security_iam_id-based-policy-examples-agent.html
- AWS docs — Working with HTTP APIs in API Gateway: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api.html
- AWS docs — Configuring logging for an HTTP API: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-logging.html
- AWS docs — Throttle requests for HTTP APIs: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html
- AWS docs — Working with AWS Lambda proxy integrations for HTTP APIs (payload format v2.0): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html
- AWS docs — JWT authorizers for HTTP APIs (consumer-attached pattern): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html
- AWS docs — Differences between REST and HTTP APIs (confirms usage plans are REST-only): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html
- AWS ML Blog — "Build generative AI agents with Amazon Bedrock" (API GW + Lambda + Bedrock pattern): https://aws.amazon.com/blogs/machine-learning/
- AWS samples — `aws-samples/amazon-bedrock-samples` (reference architectures for fronting agents with API GW + Lambda)
- Terraform provider — `aws_apigatewayv2_api`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_api
- Terraform provider — `aws_apigatewayv2_stage` (`default_route_settings.throttling_rate_limit`, `throttling_burst_limit`, `access_log_settings.destination_arn`, `format`): https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_stage
- Terraform provider — `aws_apigatewayv2_integration` (`integration_type = "AWS_PROXY"`, `payload_format_version = "2.0"`): https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_integration
- Terraform provider — `aws_apigatewayv2_route`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_route
- Terraform provider — `aws_apigatewayv2_authorizer` (consumer attaches): https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_authorizer
- Terraform provider — `aws_lambda_function`, `aws_lambda_permission`, `aws_iam_role`, `aws_cloudwatch_log_group`
- Public registry — `terraform-aws-modules/apigateway-v2/aws`: https://registry.terraform.io/modules/terraform-aws-modules/apigateway-v2/aws/latest
- Public registry — `terraform-aws-modules/lambda/aws`: https://registry.terraform.io/modules/terraform-aws-modules/lambda/aws/latest
