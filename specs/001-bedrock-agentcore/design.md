# Module Design: terraform-aws-bedrock-agentcore

**Branch**: feat/001-bedrock-agentcore
**Date**: 2026-05-06
**Status**: Draft
**Provider**: aws >= 5.50, time >= 0.11, opensearch >= 2.3
**Terraform**: >= 1.14

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Resources & Architecture](#2-resources--architecture)
3. [Interface Contract](#3-interface-contract)
4. [Security Controls](#4-security-controls)
5. [Test Scenarios](#5-test-scenarios)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

This module provisions a fully operational Amazon Bedrock agent runtime with secure-by-default cryptography, audit logging, distributed tracing, and least-privilege access. It is consumed by application platform teams that want to ship a working generative-AI agent without re-implementing the AWS Well-Architected Security Pillar baseline (encryption, IAM scoping, log retention, confused-deputy guards) on every project. The module bundles the agent itself, a stable invocation alias, an always-on code interpreter, optional Lambda-backed action groups, an optional retrieval-augmented knowledge base, an optional public HTTP endpoint, and optional content-safety guardrail association — all wired together with the operational quirks (prepare ordering, eventual consistency, AOSS index pre-creation, Lambda resource policies) that consumers should not have to discover for themselves.

**Scope boundary**: The module does NOT create the Bedrock guardrail itself (consumers bring `guardrail_id` or omit), does NOT own the knowledge-base S3 source bucket (consumers bring `knowledge_base_s3_bucket_arn`), does NOT attach an authorizer to the optional API Gateway (consumers attach their own JWT/Lambda/IAM authorizer using the exposed outputs), does NOT manage the account/region-singleton `aws_bedrock_model_invocation_logging_configuration`, and does NOT cover the separate AWS "Bedrock AgentCore" containerized-runtime product (`aws_bedrockagentcore_*` resources) — that is a candidate for a future sibling module.

### Requirements

**Functional requirements** -- what the module must do:

- Provision an agent runtime backed by a configurable foundation model with a configurable instruction prompt, returning a stable invocation handle the consumer can call.
- Enable a code-interpreter capability by default, and allow it to be disabled via a single toggle.
- Allow zero or more Lambda-backed action groups to be attached via a single map-shaped input where each map key is the action group name.
- Optionally provision a retrieval-augmented knowledge base over a consumer-supplied S3 bucket, including the underlying vector store, with a single enable toggle.
- Optionally expose the agent over an HTTP endpoint with throttling and access logging enabled, while leaving authorization to the consumer.
- Optionally bind a consumer-supplied content-safety guardrail to the agent.
- Emit identifiers and ARNs needed for downstream observability, IAM, and SDK integration.
- Accept four required organizational tags (`environment`, `owner`, `cost_center`, `project`) plus an optional free-form tag map, applying both to every taggable resource.

**Non-functional requirements** -- constraints that bound the design:

- Encryption at rest with a customer-managed key, audit logging to CloudWatch with retention, and X-Ray tracing permissions are non-negotiable: there are no toggles that disable them.
- The agent execution role must use only specific resource ARNs in its inline policy, with the documented exception of the X-Ray segment-write actions, which AWS does not support at resource-level granularity.
- The trust policy on every service role must include `aws:SourceAccount` and `aws:SourceArn` confused-deputy conditions per AWS cross-service guidance.
- Provider versions must use `>=` constraints per constitution §4.1; Terraform >= 1.14.
- The module must be region-portable across the Bedrock-Agents-supported regions (with a documented narrower list for the code interpreter and embedding model defaults) and must not hard-code the partition.
- Compliance baseline: AWS Well-Architected Security + Operational Excellence pillars (SEC03-BP02, SEC04-BP01, SEC08-BP02, OPS04), CIS AWS Foundations Benchmark v3.0.0 controls 1.16, 1.22, 3.4, 3.8, NIST 800-53 AC-6 / AU-2 / AU-9 / SC-12 / SC-13 / SC-28, and NIST AI RMF MAP-2.3 / MEASURE-2.6.

---

## 2. Resources & Architecture

### Architectural Decisions

**Resource family**: Build on the classic `aws_bedrockagent_*` resource family, NOT `aws_bedrockagentcore_*`. *Rationale*: The functional requirements (foundation model + instruction + action groups + knowledge base + alias) match the schema of `aws_bedrockagent_agent` (`agent_name`, `foundation_model`, `instruction`, `idle_session_ttl_in_seconds`, `customer_encryption_key_arn`); the AgentCore family is a separate containerized-runtime product with `agent_runtime_artifact.container_configuration` and `protocol_configuration.server_protocol`. *Source*: research-bedrock-agent-resources.md (Decision + Terminology Note); AWS provider docs `aws_bedrockagent_agent` v6.x. *Rejected*: `aws_bedrockagentcore_agent_runtime` (different abstraction — container image + network config), `awscc_bedrock_agent` mega-resource (Cloud Control schema lags `aws_*` and pulls in a second provider).

**Action group composition**: Use `for_each` over `map(object({...}))` keyed by action group name for Lambda-backed action groups, plus dedicated singleton resources for the AWS-managed code interpreter signature. *Rationale*: A map-keyed `for_each` gives consumers single-tool, multi-tool, and zero-tool configurations from one variable without module-source changes; named keys produce stable Terraform addresses; and the code interpreter has a forbidden-fields constraint (`description`, `api_schema`, `action_group_executor` MUST be omitted when `parent_action_group_signature = "AMAZON.CodeInterpreter"`) that is cleaner to express as its own resource block. *Source*: research-bedrock-agent-resources.md (Resources Identified, modes 1-6); AWS API reference `CreateAgentActionGroup`. *Rejected*: One Terraform resource per logical tool (inflexible — every new tool requires a module-source change), inline `parent_action_group_signature` on the agent itself (not a real schema option).

**Prepare-and-alias ordering**: Set `prepare_agent = false` on `aws_bedrockagent_agent`, leave `prepare_agent = true` (default) on every `aws_bedrockagent_agent_action_group`, insert a `time_sleep.wait_after_prepare` of 10 seconds before the alias, pin `routing_configuration.agent_version = aws_bedrockagent_agent.this.agent_version` on the alias, and `lifecycle { ignore_changes = [routing_configuration] }`. *Rationale*: The agent-level `prepare_agent` does not re-prepare on action-group changes; the action-group-level flag does. Letting the last action-group apply trigger the final prepare avoids 2N redundant prepares on first create. The `time_sleep` works around a known eventual-consistency window where AWS reports prepare complete a beat before the new `agent_version` is addressable from `CreateAgentAlias`. The `ignore_changes` block prevents alias churn on subsequent applies. *Source*: research-bedrock-agent-resources.md (Lifecycle Ordering & Explicit Dependencies points 3-4); Flaconi/bedrock-agent/aws v1.2.1 reference module. *Rejected*: Setting agent-level `prepare_agent = true` AND action-group-level `prepare_agent = true` (causes double/triple prepare on first apply), pinning `routing_configuration.agent_version` without `ignore_changes` (causes alias churn on every apply).

**Knowledge base vector store**: When `enable_knowledge_base = true`, default to OpenSearch Serverless (AOSS) `VECTORSEARCH` collection with Titan Embed Text v2 at 1024 dimensions and `FIXED_SIZE` chunking (300 tokens, 20% overlap). Module owns the collection, both security policies (encryption + network), the data-access policy, the IAM execution role, and pre-creates the k-NN vector index using the `opensearch_index` resource. *Rationale*: AOSS is the only vector store AWS provisions on the console "quick create" flow, requires no separate vendor account or VPC/Aurora cluster lifecycle, and is fully managed; Titan v2 is GA in all KB-supported regions and half the price of Cohere Embed English v3; `FIXED_SIZE` 300/20% is the AWS console default and the empirically robust choice for general corpora; `opensearch_index` (with SigV4 auth) is cleaner than a `null_resource` + `awscurl` for index pre-creation. *Source*: research-bedrock-knowledge-base.md (Decision + Rationale paragraphs 1-3 + AOSS index timing). *Rejected*: Aurora pgvector (multiplies module resource count by ~8 for subnets/parameter groups/backups/password rotation), Pinecone/MongoDB (third-party credentials break the lifecycle), `null_resource` + `local-exec` for index creation (breaks pure-Terraform CI by requiring `awscurl`/`curl` on operator machines), requiring consumers to pre-create the AOSS collection (defeats the one-toggle convenience).

**HTTP API frontend**: When `enable_api_gateway = true`, provision an API Gateway v2 HTTP API + auto-deployed `$default` stage + `AWS_PROXY` integration to a small bundled invoker Lambda (Python 3.12) that calls `bedrock-agent-runtime:InvokeAgent`. NO authorizer, NO CORS by default; throttle defaults rate=100/burst=200; access logging always on with KMS-encrypted log group. *Rationale*: Bedrock agents have no native HTTPS endpoint and `InvokeAgent` returns a streaming `EventStream` that API Gateway cannot translate to JSON without a Lambda transformer. HTTP API (v2) is ~70% cheaper than REST API and lower latency. Authorization is environment-specific (Cognito ARN, JWT issuer, IAM, custom Lambda) and changes more often than the API surface, so it stays a consumer concern with `api_id`/`default_route_key`/`api_execution_arn` exposed for in-place attachment. *Source*: research-bedrock-api-gateway.md (Decision + Rationale points 1-3). *Rejected*: REST API v1 (higher cost, higher latency, no JWT authorizer; only justified for usage plans which v1-only), Lambda Function URL (loses pluggable authorizer ecosystem and per-route throttling), bake-in Cognito authorizer by default (forces every consumer to either accept Cognito or rip it out).

**KMS encryption strategy**: Module always passes a customer-managed KMS key ARN to the agent and the log group; if `kms_key_arn` is empty, the module creates `aws_kms_key.this` with `enable_key_rotation = true` and `deletion_window_in_days = 30`. Key policy grants the regional `logs.<region>.amazonaws.com` service principal with an `kms:EncryptionContext:aws:logs:arn` condition pinned to the agent log group ARN, the `bedrock.amazonaws.com` service principal with `aws:SourceAccount` + `kms:ViaService` conditions, and the agent execution role `kms:Decrypt` + `kms:GenerateDataKey`. NO disable flag. *Rationale*: AWS-owned keys are not customer-visible and CIS Bedrock guidance flags them as non-compliant for production; Bedrock uses a dual-control model where both the IAM policy and the KMS key policy must allow the role; CloudWatch Logs uses the regional logs service principal in the key policy, not a trust policy. *Source*: research-bedrock-security-iam-kms.md (Decision + Rationale paragraphs 1-2); AWS KMS Developer Guide `kms:ViaService`. *Rejected*: AWS-owned encryption (cannot satisfy "secure by default with no opt-out" requirement), `kms.<region>.amazonaws.com` as `kms:ViaService` (not a real service — must reference the calling service).

**Provider version selection**: `aws >= 5.50` (first version exposing the modern `aws_bedrockagent_*` schema with `function_schema.member_functions` and `vector_knowledge_base_configuration.embedding_model_configuration`), `time >= 0.11` (for `time_sleep`), `opensearch >= 2.3` (first version of opensearch-project provider with stable AOSS + SigV4 support for the `opensearch_index` resource). *Rationale*: Use `>=` per constitution §4.1 to maximize consumer compatibility; the chosen minimums are the lowest known to support the schema features used. *Source*: research-bedrock-agent-resources.md (Sources — provider 6.x docs); research-bedrock-knowledge-base.md (Sources — `opensearch_index` reference).

**Action group `for_each` accessor pattern in tests**: Action groups created via `for_each` are addressed by their map key — assertions use `aws_bedrockagent_agent_action_group.lambda["my-tool"].action_group_name`, not `[0]`. *Rationale*: `for_each` with a string-keyed map produces stable, named addresses; `count`-style `[0]` indexing would require ordering assumptions. *Source*: research-bedrock-agent-resources.md (Rationale: "Why `for_each` for action groups").

### Resource Inventory

| Resource Type | Logical Name | Conditional | Depends On | Key Configuration | Schema Notes |
|---------------|-------------|-------------|------------|-------------------|--------------|
| `aws_kms_key` | `this` | `var.kms_key_arn == ""` | -- | `enable_key_rotation = true`, `deletion_window_in_days = 30`, `policy` grants account root + `logs.<region>.amazonaws.com` + `bedrock.amazonaws.com` + execution role | `--` |
| `aws_kms_alias` | `this` | `var.kms_key_arn == ""` | `aws_kms_key.this` | `name = "alias/bedrock-agent-${var.agent_name}"` | `--` |
| `aws_cloudwatch_log_group` | `agent` | always | local KMS key arn (created or BYO) | `name = "/aws/bedrock/agents/${var.agent_name}"`, `kms_key_id` always set, `retention_in_days = var.log_retention_days` (default 90) | `--` |
| `aws_iam_role` | `agent` | always | -- | `assume_role_policy` for `bedrock.amazonaws.com` with `aws:SourceAccount` + `aws:SourceArn = arn:${partition}:bedrock:${region}:${account}:agent/*` | `--` |
| `aws_iam_role_policy` | `agent` | always | `aws_iam_role.agent`, log group, KMS key, optional Lambda ARNs, optional KB ARN, optional guardrail ARN | Inline policy: `bedrock:InvokeModel*` on FM ARN, `logs:*` on log group ARN, `kms:Decrypt`/`GenerateDataKey`/`DescribeKey` on CMK with `kms:ViaService` cond, `xray:PutTraceSegments`/`PutTelemetryRecords` on `*` (documented exception), conditional `lambda:InvokeFunction` on action-group Lambda ARNs, conditional `bedrock:Retrieve`/`RetrieveAndGenerate` on KB ARN, conditional `bedrock:ApplyGuardrail` on guardrail ARN | `--` |
| `aws_bedrockagent_agent` | `this` | always | `aws_iam_role.agent`, KMS key, log group | `agent_name`, `foundation_model = var.foundation_model`, `instruction = var.instruction`, `customer_encryption_key_arn` always set, `prepare_agent = false`, `idle_session_ttl_in_seconds = var.idle_session_ttl_seconds`, conditional `guardrail_configuration` block when `var.guardrail_id != ""` | `guardrail_configuration` is list-typed `[0]`, `prompt_override_configuration` is list-typed `[0]`, `memory_configuration` is list-typed `[0]` |
| `aws_bedrockagent_agent_action_group` | `code_interpreter` | `var.enable_code_interpreter` | `aws_bedrockagent_agent.this` | `action_group_name = "CodeInterpreterAction"`, `agent_version = "DRAFT"`, `parent_action_group_signature = "AMAZON.CodeInterpreter"`, `prepare_agent = true`; `description`/`api_schema`/`action_group_executor` deliberately omitted (API requirement) | `api_schema` / `function_schema` / `action_group_executor` all list-typed `[0]` (none set on this resource) |
| `aws_bedrockagent_agent_action_group` | `lambda` (for_each over `var.action_group_definitions`) | `length(var.action_group_definitions) > 0` | `aws_bedrockagent_agent.this`, `aws_lambda_permission.bedrock_invoke[each.key]` | `action_group_name = each.key`, `agent_version = "DRAFT"`, `description = each.value.description`, `action_group_executor.lambda = each.value.lambda_arn`, conditional `api_schema` (payload OR s3 sub-block) OR `function_schema`, `prepare_agent = true`, `skip_resource_in_use_check = var.force_destroy` | `action_group_executor` list `[0]`, `api_schema` list `[0]` (with nested `s3` list `[0]`), `function_schema` list `[0]` (with nested `member_functions` list `[0]`); each Lambda action group needs explicit `depends_on = [aws_lambda_permission.bedrock_invoke[each.key]]` |
| `aws_lambda_permission` | `bedrock_invoke` (for_each over `var.action_group_definitions`) | `length(var.action_group_definitions) > 0` | `aws_bedrockagent_agent.this` | `statement_id_prefix = "AllowBedrockInvoke-"`, `action = "lambda:InvokeFunction"`, `principal = "bedrock.amazonaws.com"`, `function_name = each.value.lambda_arn`, `source_arn = aws_bedrockagent_agent.this.agent_arn`. MANDATORY per research — without it, runtime invocations 403 silently | `--` |
| `time_sleep` | `wait_after_prepare` | always | `aws_bedrockagent_agent_action_group.code_interpreter`, `aws_bedrockagent_agent_action_group.lambda` (all keys) | `create_duration = "${var.wait_after_prepare_seconds}s"` (default 10s); works around eventual-consistency between `PrepareAgent` reporting complete and `agent_version` becoming addressable | `--` |
| `aws_bedrockagent_agent_alias` | `this` | always | `time_sleep.wait_after_prepare` | `agent_alias_name = var.agent_alias_name`, `agent_id = aws_bedrockagent_agent.this.agent_id`, `routing_configuration.agent_version = aws_bedrockagent_agent.this.agent_version`, `lifecycle { ignore_changes = [routing_configuration] }` | `routing_configuration` is list-typed `[0]` |
| `aws_iam_role` | `kb` | `var.enable_knowledge_base` | -- | Trust policy `bedrock.amazonaws.com` with `aws:SourceAccount` + `aws:SourceArn = arn:${partition}:bedrock:${region}:${account}:knowledge-base/*` confused-deputy guards | `--` |
| `aws_iam_role_policy` | `kb` | `var.enable_knowledge_base` | `aws_iam_role.kb`, AOSS collection, S3 bucket, KMS key | `bedrock:InvokeModel` on embedding model ARN, `s3:GetObject`+`s3:ListBucket` on `var.knowledge_base_s3_bucket_arn` (with `s3:prefix` condition if `inclusion_prefixes` set), `aoss:APIAccessAll` on AOSS collection ARN, `kms:Decrypt`/`GenerateDataKey` on CMK + optional `var.knowledge_base_s3_kms_key_arn` | `--` |
| `aws_opensearchserverless_security_policy` | `encryption` | `var.enable_knowledge_base` | -- | `type = "encryption"`, `policy` JSON sets `AWSOwnedKey` or CMK on the collection ARN | `--` |
| `aws_opensearchserverless_security_policy` | `network` | `var.enable_knowledge_base` | -- | `type = "network"`, `policy` JSON: `AllowFromPublic = true` for basic, false for production (recommend VPC endpoint) | `--` |
| `aws_opensearchserverless_collection` | `kb` | `var.enable_knowledge_base` | `aws_opensearchserverless_security_policy.encryption`, `aws_opensearchserverless_security_policy.network` | `name = "${var.agent_name}-kb"`, `type = "VECTORSEARCH"` | `--` |
| `aws_opensearchserverless_access_policy` | `kb` | `var.enable_knowledge_base` | `aws_opensearchserverless_collection.kb`, `aws_iam_role.kb` | `type = "data"`, principal = KB role ARN, permissions = `aoss:CreateIndex`/`UpdateIndex`/`DescribeIndex`/`ReadDocument`/`WriteDocument`/`DescribeCollectionItems` scoped to the collection + index | `--` |
| `time_sleep` | `wait_aoss_dap` | `var.enable_knowledge_base` | `aws_opensearchserverless_access_policy.kb` | `create_duration = "60s"` — AOSS data-access-policy propagation is eventually consistent and a known source of `AccessDeniedException` on first apply | `--` |
| `opensearch_index` | `kb` | `var.enable_knowledge_base` | `aws_opensearchserverless_collection.kb`, `time_sleep.wait_aoss_dap` | `name = "${var.agent_name}-index"`, `mappings` JSON with `vector` field (knn_vector dim 1024), `text` field, `metadata` field — must match the field_mapping on the KB | `--` |
| `aws_bedrockagent_knowledge_base` | `this` | `var.enable_knowledge_base` | `aws_iam_role.kb`, `opensearch_index.kb` | `name = "${var.agent_name}-kb"`, `role_arn`, `knowledge_base_configuration` (`type = "VECTOR"`, `vector_knowledge_base_configuration.embedding_model_arn` defaulted to Titan v2, `embedding_model_configuration.bedrock_embedding_model_configuration.dimensions = 1024`), `storage_configuration` (`type = "OPENSEARCH_SERVERLESS"`, collection_arn, vector_index_name, field_mapping) | `knowledge_base_configuration` list `[0]`, `vector_knowledge_base_configuration` list `[0]`, `embedding_model_configuration` list `[0]`, `storage_configuration` list `[0]`, `opensearch_serverless_configuration` list `[0]`, `field_mapping` list `[0]` |
| `aws_bedrockagent_data_source` | `this` | `var.enable_knowledge_base` | `aws_bedrockagent_knowledge_base.this` | `knowledge_base_id`, `name`, `data_source_configuration.type = "S3"`, `s3_configuration.bucket_arn = var.knowledge_base_s3_bucket_arn`, `vector_ingestion_configuration.chunking_configuration.chunking_strategy = "FIXED_SIZE"` (300 tokens / 20% overlap), `data_deletion_policy = "RETAIN"` | `data_source_configuration` list `[0]`, `s3_configuration` list `[0]`, `vector_ingestion_configuration` list `[0]`, `chunking_configuration` list `[0]` |
| `aws_bedrockagent_agent_knowledge_base_association` | `this` | `var.enable_knowledge_base` | `aws_bedrockagent_agent.this`, `aws_bedrockagent_knowledge_base.this` | `agent_id`, `agent_version = "DRAFT"`, `knowledge_base_id`, `description = var.knowledge_base_description`, `knowledge_base_state = "ENABLED"` | `--` |
| `aws_iam_role` | `lambda` | `var.enable_api_gateway` | -- | Trust policy `lambda.amazonaws.com` | `--` |
| `aws_iam_role_policy` | `lambda` | `var.enable_api_gateway` | `aws_iam_role.lambda`, `aws_bedrockagent_agent_alias.this`, log group, KMS key | `bedrock:InvokeAgent` on agent_alias_arn, `logs:CreateLogStream`/`PutLogEvents` on Lambda log group, `kms:Decrypt`/`GenerateDataKey` on CMK, `xray:PutTraceSegments`/`PutTelemetryRecords` on `*` | `--` |
| `aws_cloudwatch_log_group` | `lambda` | `var.enable_api_gateway` | KMS key | `name = "/aws/lambda/${var.agent_name}-invoker"`, `kms_key_id` always set, `retention_in_days = var.log_retention_days` | `--` |
| `aws_lambda_function` | `invoker` | `var.enable_api_gateway` | `aws_iam_role.lambda`, `aws_iam_role_policy.lambda`, `aws_cloudwatch_log_group.lambda` | `function_name = "${var.agent_name}-invoker"`, `runtime = "python3.12"`, `handler = "index.handler"`, `timeout = 90`, `memory_size = 256`, `tracing_config { mode = "Active" }`, source from bundled `files/invoker/` zipped via `archive_file` data source | `tracing_config` list `[0]`, `environment` list `[0]`, `vpc_config` list `[0]` |
| `aws_lambda_permission` | `apigw_invoke` | `var.enable_api_gateway` | `aws_lambda_function.invoker`, `aws_apigatewayv2_api.this` | `action = "lambda:InvokeFunction"`, `principal = "apigateway.amazonaws.com"`, `source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/*"` | `--` |
| `aws_apigatewayv2_api` | `this` | `var.enable_api_gateway` | -- | `name = "${var.agent_name}-api"`, `protocol_type = "HTTP"`, `cors_configuration` omitted (consumer opt-in via `var.cors_configuration`) | `cors_configuration` list `[0]` (omitted by default) |
| `aws_apigatewayv2_integration` | `lambda` | `var.enable_api_gateway` | `aws_apigatewayv2_api.this`, `aws_lambda_function.invoker` | `integration_type = "AWS_PROXY"`, `integration_uri = aws_lambda_function.invoker.invoke_arn`, `payload_format_version = "2.0"`, `timeout_milliseconds = 30000` (HTTP API hard cap) | `--` |
| `aws_apigatewayv2_route` | `invoke` | `var.enable_api_gateway` | `aws_apigatewayv2_integration.lambda` | `route_key = "POST /invoke"`, `target = "integrations/${aws_apigatewayv2_integration.lambda.id}"`, `authorization_type = "NONE"` (consumer attaches own authorizer via outputs) | `--` |
| `aws_cloudwatch_log_group` | `apigw_access` | `var.enable_api_gateway` | KMS key | `name = "/aws/apigateway/${var.agent_name}-api/access-logs"`, `kms_key_id` always set, `retention_in_days = var.log_retention_days` | `--` |
| `aws_apigatewayv2_stage` | `default` | `var.enable_api_gateway` | `aws_apigatewayv2_api.this`, `aws_cloudwatch_log_group.apigw_access` | `name = "$default"`, `auto_deploy = true`, `default_route_settings { throttling_rate_limit = var.api_throttling_rate_limit (100), throttling_burst_limit = var.api_throttling_burst_limit (200) }`, `access_log_settings { destination_arn = log_group.arn, format = JSON template }` | `default_route_settings` list `[0]`, `access_log_settings` list `[0]`, `route_settings` is set-typed (use `one()` for assertions) |

Data sources (in `data.tf`): `aws_caller_identity.current`, `aws_partition.current`, `aws_region.current`, `archive_file.invoker_zip` (conditional on `var.enable_api_gateway`).

---

## 3. Interface Contract

### Inputs

| Variable | Type | Required | Default | Validation | Sensitive | Description |
|----------|------|----------|---------|------------|-----------|-------------|
| `agent_name` | `string` | Yes | -- | `length >= 1 && length <= 100 && can(regex("^[A-Za-z0-9_-]+$", v))` | No | Stable name for the Bedrock agent and the prefix for derived resource names (KMS alias, log groups, IAM roles, AOSS collection). |
| `instruction` | `string` | Yes | -- | `length >= 40 && length <= 20000` | No | Natural-language instruction prompt that defines the agent's behavior. AWS API requires 40-20000 chars when `prepare_agent` runs. |
| `foundation_model` | `string` | No | `"anthropic.claude-sonnet-4-20250514"` | `length >= 1` | No | Bedrock foundation model ID. Default is Claude Sonnet 4. Consumer must verify model availability in target region. |
| `agent_alias_name` | `string` | No | `"live"` | `length >= 1 && length <= 100` | No | Name of the stable invocation alias pinned to the prepared agent version. |
| `idle_session_ttl_seconds` | `number` | No | `600` | `v >= 60 && v <= 3600` | No | Session idle timeout. Bedrock-allowed range 60-3600 seconds. |
| `enable_code_interpreter` | `bool` | No | `true` | -- | No | Attach the AWS-managed `AMAZON.CodeInterpreter` action group. Region-restricted: us-east-1, us-west-2, eu-central-1 only. |
| `action_group_definitions` | `map(object({ description = string, lambda_arn = string, api_schema = optional(object({ payload = optional(string), s3 = optional(object({ s3_bucket_name = string, s3_object_key = string })) })), function_schema = optional(object({ functions = list(object({ name = string, description = string, parameters = optional(map(object({ type = string, description = string, required = optional(bool, false) }))) })) })) }))` | No | `{}` | For each value, exactly one of `api_schema` or `function_schema` must be set; if `api_schema` is set, exactly one of `payload` or `s3` must be set. | No | Map of Lambda-backed action groups keyed by action group name. Each value provides description, target Lambda ARN, and either an OpenAPI schema (inline payload OR S3 location) or a function schema. The module creates one `aws_bedrockagent_agent_action_group` plus one `aws_lambda_permission` per entry. |
| `enable_knowledge_base` | `bool` | No | `false` | -- | No | When true, provision the AOSS-backed knowledge base, IAM role, vector index, KB resource, S3 data source, and agent association. |
| `knowledge_base_s3_bucket_arn` | `string` | No | `""` | When `enable_knowledge_base = true`, must be non-empty and match `^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$`. | No | ARN of the consumer-supplied S3 bucket containing source documents for the knowledge base. Module never creates the bucket. |
| `knowledge_base_inclusion_prefixes` | `list(string)` | No | `[]` | -- | No | Optional S3 key prefixes to restrict which objects in the bucket are ingested. When set, S3 IAM permissions are scoped via `s3:prefix`. |
| `knowledge_base_s3_kms_key_arn` | `string` | No | `""` | If non-empty, must match `^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$`. | No | Optional CMK ARN if the source S3 bucket uses a customer-managed key; the KB role is granted `kms:Decrypt` on this key. |
| `knowledge_base_embedding_model_id` | `string` | No | `"amazon.titan-embed-text-v2:0"` | `length >= 1` | No | Embedding model ID for vectorization. Default Titan v2 at 1024 dimensions. |
| `knowledge_base_description` | `string` | No | `"Use this knowledge base to retrieve relevant context from the customer document corpus."` | `length >= 1 && length <= 1000` | No | Natural-language description used by the agent's planner to decide when to query the KB. This is functional, not cosmetic. |
| `enable_api_gateway` | `bool` | No | `false` | -- | No | When true, provision an HTTP API + invoker Lambda + access log group. The route is unauthenticated by default; consumer attaches authorizer using exposed outputs. |
| `api_throttling_rate_limit` | `number` | No | `100` | `v > 0 && v <= 10000` | No | Steady-state requests-per-second throttle on the API stage. |
| `api_throttling_burst_limit` | `number` | No | `200` | `v > 0 && v <= 10000` | No | Token-bucket burst limit on the API stage. |
| `cors_configuration` | `object({ allow_origins = list(string), allow_methods = list(string), allow_headers = list(string), max_age = optional(number, 0) })` | No | `null` | -- | No | Optional CORS configuration for the HTTP API. Disabled when null (default). Setting `allow_origins = ["*"]` is a security smell; document tradeoff in README. |
| `guardrail_id` | `string` | No | `""` | If non-empty, must match `^[a-z0-9]+$`. | No | Optional consumer-provided Bedrock Guardrail identifier to bind to the agent. Module does NOT create the guardrail in v1. |
| `guardrail_version` | `string` | No | `"DRAFT"` | When `guardrail_id != ""`, must match `^([0-9]+|DRAFT)$`. Pinning a numeric version is recommended for production. | No | Guardrail version to pin. Defaults to `DRAFT` (mutable); pin to a numbered version in production examples. |
| `kms_key_arn` | `string` | No | `""` | If non-empty, must match `^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$`. | No | Bring-your-own KMS CMK ARN. When empty, the module creates one with rotation enabled. Encryption is non-negotiable; this only controls key ownership. |
| `log_retention_days` | `number` | No | `90` | `contains([1,3,5,7,14,30,60,90,120,150,180,365,400,545,731,1827,3653], v)` | No | Retention for all CloudWatch log groups created by the module. Validated against CloudWatch Logs allowed values. |
| `wait_after_prepare_seconds` | `number` | No | `10` | `v >= 0 && v <= 120` | No | Delay between the final `PrepareAgent` and `CreateAgentAlias` to work around eventual-consistency on `agent_version`. Set 0 to disable. |
| `force_destroy` | `bool` | No | `false` | -- | No | When true, sets `skip_resource_in_use_check = true` on action groups and the agent so `terraform destroy` can run while the alias references them. Off by default for safety. |
| `environment` | `string` | Yes | -- | `contains(["dev","staging","prod","sandbox","test"], v)` | No | Required organizational tag identifying deployment environment. Applied to every taggable resource via `local.required_tags`. |
| `owner` | `string` | Yes | -- | `length >= 1 && length <= 256` | No | Required organizational tag identifying the owning team or person (e.g., `team-genai@example.com`). |
| `cost_center` | `string` | Yes | -- | `length >= 1 && length <= 64` | No | Required organizational tag identifying the cost center for chargeback. |
| `project` | `string` | Yes | -- | `length >= 1 && length <= 128` | No | Required organizational tag identifying the project for grouping and reporting. |
| `tags` | `map(string)` | No | `{}` | -- | No | Free-form additional tags merged with required tags and `Name` / `ManagedBy = "terraform"` defaults. Consumer-provided keys override module defaults. |

### Outputs

| Output | Type | Conditional On | Description |
|--------|------|----------------|-------------|
| `agent_id` | `string` | always | Short identifier of the Bedrock agent (e.g., `GGRRAED6JP`). Use this in cross-resource references. |
| `agent_arn` | `string` | always | Full ARN of the Bedrock agent. |
| `agent_version` | `string` | always | Current prepared agent version (numeric, e.g., `"1"`). |
| `agent_alias_id` | `string` | always | Identifier of the stable invocation alias. |
| `agent_alias_arn` | `string` | always | Full ARN of the agent alias — the invocation target consumers should use with `bedrock-agent-runtime:InvokeAgent`. |
| `agent_role_arn` | `string` | always | ARN of the agent execution role for downstream IAM policy references. |
| `kms_key_arn` | `string` | always | ARN of the KMS CMK used for at-rest encryption (created by the module or passed in). |
| `log_group_name` | `string` | always | Name of the agent CloudWatch log group. |
| `log_group_arn` | `string` | always | ARN of the agent CloudWatch log group. |
| `knowledge_base_id` | `string` | `var.enable_knowledge_base` (uses `try(...,null)`) | Identifier of the Bedrock knowledge base, or `null` when disabled. |
| `knowledge_base_arn` | `string` | `var.enable_knowledge_base` (uses `try(...,null)`) | ARN of the Bedrock knowledge base, or `null` when disabled. |
| `knowledge_base_role_arn` | `string` | `var.enable_knowledge_base` (uses `try(...,null)`) | ARN of the KB execution role. |
| `data_source_id` | `string` | `var.enable_knowledge_base` (uses `try(...,null)`) | Identifier of the KB S3 data source — needed to trigger ingestion via the SDK (`StartIngestionJob`). |
| `opensearch_collection_arn` | `string` | `var.enable_knowledge_base` (uses `try(...,null)`) | ARN of the AOSS vector collection. |
| `api_id` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | API Gateway v2 HTTP API identifier. Use with `aws_apigatewayv2_authorizer` to attach an authorizer. |
| `api_endpoint` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | Invoke URL of the HTTP API (`https://<id>.execute-api.<region>.amazonaws.com`). |
| `api_arn` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | ARN of the API Gateway HTTP API for resource policies / WAFv2 association. |
| `api_execution_arn` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | Execution ARN of the API for `aws_lambda_permission.source_arn` if the consumer adds more integrations. |
| `default_route_key` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | The default route key (`POST /invoke`) — used by consumers when overriding `authorization_type` via `aws_apigatewayv2_route`. |
| `invoker_lambda_arn` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | ARN of the bundled invoker Lambda function. |
| `invoker_lambda_name` | `string` | `var.enable_api_gateway` (uses `try(...,null)`) | Name of the bundled invoker Lambda function. |

---

## 4. Security Controls

| Control | Enforcement | Configurable? | Reference |
|---------|-------------|---------------|-----------|
| Encryption at rest | Customer-managed KMS CMK is always passed to `aws_bedrockagent_agent.customer_encryption_key_arn` and `aws_cloudwatch_log_group.kms_key_id`. Module creates `aws_kms_key.this` with `enable_key_rotation = true`, `deletion_window_in_days = 30` when `var.kms_key_arn == ""`. Key policy grants regional `logs.<region>.amazonaws.com` (with `kms:EncryptionContext:aws:logs:arn` cond), `bedrock.amazonaws.com` (with `aws:SourceAccount` + `kms:ViaService` cond), and the agent execution role. | Partial (key ownership only — BYO via `var.kms_key_arn`). NO disable flag. | AWS Well-Architected SEC08-BP02 (encrypt at rest); CIS AWS 3.8 (KMS rotation enabled); NIST 800-53 SC-12, SC-13, SC-28; Trivy AVD-AWS-0017, AVD-AWS-0342; Checkov CKV_AWS_158, CKV2_AWS_67 |
| Encryption in transit | Enforced by AWS service endpoints — all `bedrock-agent`, `bedrock-agent-runtime`, AOSS, KMS, CloudWatch Logs, API Gateway, and Lambda traffic is TLS 1.2+ via the AWS service plane. API Gateway v2 HTTP API serves only HTTPS (`https://<id>.execute-api.<region>.amazonaws.com`). | No (platform-enforced) | AWS Well-Architected SEC09-BP02 (encrypt in transit); CIS AWS 4.1; NIST 800-53 SC-8 |
| Public access | Bedrock control-plane and agent-runtime APIs are SigV4-only — no public anonymous access path exists. AOSS network policy default in `examples/basic` is `AllowFromPublic = true` (lab-friendly) but `examples/complete` and the README recommend `AllowFromPublic = false` + VPC endpoint for production. API Gateway HTTP API is publicly resolvable but the route's `authorization_type = "NONE"` is documented prominently and consumers MUST attach an authorizer for production. | Partial (AOSS network policy; API authorizer is consumer responsibility). | AWS Well-Architected SEC05-BP02 (control traffic); NIST 800-53 SC-7 (boundary protection); AWS API Gateway authorizer guidance |
| IAM least privilege | Agent execution role inline policy scopes `bedrock:InvokeModel*` to the foundation model ARN, `logs:*` to the agent log group ARN, `kms:*` to the CMK ARN with `kms:ViaService` condition, conditional `lambda:InvokeFunction` to explicit action-group Lambda ARNs (with `AWS:SourceAccount` cond), conditional `bedrock:Retrieve`/`RetrieveAndGenerate` to the KB ARN, conditional `bedrock:ApplyGuardrail` to the guardrail ARN. All trust policies use `bedrock.amazonaws.com` with `aws:SourceAccount` + `aws:SourceArn` confused-deputy guards. The KB role and Lambda execution role follow the same scoping rules. The ONE exception is `xray:PutTraceSegments` + `xray:PutTelemetryRecords` on `Resource: "*"`, required because X-Ray does not support resource-level permissions for these two actions (documented in code and §7). | No (policy generation is internal) | AWS Well-Architected SEC03-BP02 (least-privilege roles); CIS AWS 1.16, 1.22; NIST 800-53 AC-6; Trivy AVD-AWS-0057, AVD-AWS-0345; Checkov CKV_AWS_109, CKV_AWS_111 |
| Logging | `aws_cloudwatch_log_group.agent` always created with `kms_key_id` set and `retention_in_days = var.log_retention_days` (default 90, validated against CloudWatch Logs allowed values). When API Gateway is enabled, `aws_cloudwatch_log_group.lambda` and `aws_cloudwatch_log_group.apigw_access` are also created with the same KMS key and retention. API Gateway access logs use a structured JSON format including `requestId`, `ip`, `requestTime`, `httpMethod`, `routeKey`, `status`, `protocol`, `responseLength`, `integrationErrorMessage`. Lambda invoker has `tracing_config { mode = "Active" }`. X-Ray distributed tracing is enabled via IAM on every role. | Retention only (`var.log_retention_days`); KMS encryption + log group existence are NOT toggleable. | AWS Well-Architected SEC04-BP01 (centralised logging), OPS04-BP01; CIS AWS 3.4 (log encryption with CMK by analogy); NIST 800-53 AU-2, AU-9; Checkov CKV_AWS_338 (recommend 365 days in production examples); Trivy AVD-AWS-0017 |
| Tagging | Required tags `environment`, `owner`, `cost_center`, `project` are enforced as required string variables with non-empty validation. `local.required_tags = merge({ Name = var.agent_name, ManagedBy = "terraform", Environment = var.environment, Owner = var.owner, CostCenter = var.cost_center, Project = var.project }, var.tags)`. Every taggable resource sets `tags = local.required_tags` so consumer-provided keys merge but cannot remove the required four. | Yes (consumer keys merge via `var.tags`) | Module constitution §3.3; AWS Well-Architected OPS04-BP02 (resource tagging); AWS Tagging Best Practices |

Additional AI-specific control: **Content safety** — When `var.guardrail_id` is non-empty, the agent's `guardrail_configuration` block binds the consumer-supplied guardrail. Module v1 does NOT create the guardrail itself; deferred to v2 per §7 [DEFERRED]. Reference: NIST AI RMF MAP-2.3 / MEASURE-2.6, AWS Bedrock Guardrails docs.

---

## 5. Test Scenarios

### Test Strategy

- **Module source**: Tests run against the **root module directly** — do NOT use `module {}` blocks in `run` blocks. Assertions reference `aws_bedrockagent_agent.this.foundation_model`, NOT `module.x.aws_bedrockagent_agent.this.foundation_model`.
- **Unit tests**: Use `mock_provider "aws" {}`, `mock_provider "time" {}`, and `mock_provider "opensearch" {}` blocks with `command = plan`. Add `mock_data "aws_caller_identity" {}`, `mock_data "aws_partition" {}`, `mock_data "aws_region" {}` blocks; add `mock_data "archive_file" {}` when API Gateway is enabled. Fast, deterministic, no credentials needed; run on every CI build.
- **Acceptance tests**: Use real providers with `command = plan`. Validates plan output against real AWS APIs without creating resources. Requires credentials. Not run during this workflow.
- **Integration tests**: Use real providers with `command = apply`. Creates and destroys real infrastructure — agent + log group + IAM + KMS at minimum, plus optional KB / API GW. Requires credentials and accepts real AWS bill. Not run during this workflow.
- **Plan-time limitations (unit tests only)**: With mock providers, provider-generated values (ARNs, IDs, endpoints, the AOSS collection endpoint, `archive_file.output_base64sha256`) are unknown, and cross-resource references through dependent resources (e.g., `agent_arn` referenced as `source_arn` on `aws_lambda_permission`) cannot be resolved. Such assertions are flagged `[plan-unknown]` so the test writer substitutes resource-existence + literal-attribute checks.
- **`for_each` accessor pattern**: Lambda action groups are addressed by their map key — assertions traverse via `aws_bedrockagent_agent_action_group.lambda["my-tool"].action_group_name` (NOT `[0]`).
- **Set-typed nested blocks**: `aws_apigatewayv2_stage.route_settings` is set-typed — use `one()` if a single override is asserted. All other nested blocks called out in Section 2 Schema Notes are list-typed `[0]`.

### Unit Tests

#### Scenario: Secure Defaults (basic)

**Purpose**: Verify the module works with minimal inputs and security is enabled by default
**Command**: `plan` (mock providers)

**Inputs**:
```hcl
agent_name   = "test-agent"
instruction  = "You are a helpful assistant. Answer user questions clearly and concisely. Use the code interpreter only when computation is required."
environment  = "test"
owner        = "team-genai@example.com"
cost_center  = "cc-1234"
project      = "agentcore-tests"
```

**Assertions**:
- Agent name matches input — `aws_bedrockagent_agent.this.agent_name == "test-agent"`
- Default foundation model is Claude Sonnet 4 — `aws_bedrockagent_agent.this.foundation_model == "anthropic.claude-sonnet-4-20250514"`
- Agent uses module-created CMK — `aws_bedrockagent_agent.this.customer_encryption_key_arn != null` `[plan-unknown]`
- Module creates one KMS key when `kms_key_arn` empty — `length(aws_kms_key.this) == 1`
- Created KMS key has rotation enabled — `aws_kms_key.this[0].enable_key_rotation == true`
- Created KMS key has 30-day deletion window — `aws_kms_key.this[0].deletion_window_in_days == 30`
- Agent log group is KMS-encrypted — `aws_cloudwatch_log_group.agent.kms_key_id != null` `[plan-unknown]`
- Agent log group retention defaults to 90 days — `aws_cloudwatch_log_group.agent.retention_in_days == 90`
- Agent log group name follows convention — `aws_cloudwatch_log_group.agent.name == "/aws/bedrock/agents/test-agent"`
- Code interpreter action group is created by default — `aws_bedrockagent_agent_action_group.code_interpreter[0].parent_action_group_signature == "AMAZON.CodeInterpreter"`
- Code interpreter description is null (API requirement) — `aws_bedrockagent_agent_action_group.code_interpreter[0].description == null`
- No Lambda-backed action groups when map empty — `length(aws_bedrockagent_agent_action_group.lambda) == 0`
- No Lambda permissions when no action groups — `length(aws_lambda_permission.bedrock_invoke) == 0`
- Agent prepare flag is disabled (action groups drive prepare) — `aws_bedrockagent_agent.this.prepare_agent == false`
- Wait-after-prepare default 10s — `time_sleep.wait_after_prepare.create_duration == "10s"`
- Alias name defaults to `live` — `aws_bedrockagent_agent_alias.this.agent_alias_name == "live"`
- Alias pinned to agent_version — `aws_bedrockagent_agent_alias.this.routing_configuration[0].agent_version != null` `[plan-unknown]`
- Knowledge base disabled by default — `length(aws_bedrockagent_knowledge_base.this) == 0`
- API Gateway disabled by default — `length(aws_apigatewayv2_api.this) == 0`
- Guardrail not configured by default — `length(aws_bedrockagent_agent.this.guardrail_configuration) == 0`
- Required tags applied to agent — `aws_bedrockagent_agent.this.tags["Environment"] == "test"`
- ManagedBy tag set — `aws_bedrockagent_agent.this.tags["ManagedBy"] == "terraform"`
- Name tag set to agent_name — `aws_bedrockagent_agent.this.tags["Name"] == "test-agent"`
- Project tag applied — `aws_bedrockagent_agent.this.tags["Project"] == "agentcore-tests"`
- Owner tag applied — `aws_bedrockagent_agent.this.tags["Owner"] == "team-genai@example.com"`
- CostCenter tag applied — `aws_bedrockagent_agent.this.tags["CostCenter"] == "cc-1234"`
- IAM role assume policy is for bedrock service — `aws_iam_role.agent.assume_role_policy != ""` (regex check for `bedrock.amazonaws.com` and `aws:SourceAccount`)
- IAM inline policy created — `aws_iam_role_policy.agent.name != ""` `[plan-unknown]`
- IAM inline policy attached to role — `aws_iam_role_policy.agent.role != null` `[plan-unknown]`
- Force destroy off by default — `aws_bedrockagent_agent.this.skip_resource_in_use_check == false`

#### Scenario: Full Features (complete)

**Purpose**: Verify all features enabled, all optional resources created, all outputs populated
**Command**: `plan` (mock providers)

**Inputs**:
```hcl
agent_name                       = "test-agent-full"
instruction                      = "You are a helpful assistant. Use available tools to answer user queries. Use the knowledge base when the user asks about company-specific topics. Use the code interpreter for computational tasks."
foundation_model                 = "anthropic.claude-sonnet-4-20250514"
agent_alias_name                 = "prod"
idle_session_ttl_seconds         = 1800
enable_code_interpreter          = true
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
enable_knowledge_base            = true
knowledge_base_s3_bucket_arn     = "arn:aws:s3:::test-corpus-bucket"
knowledge_base_inclusion_prefixes = ["docs/", "policies/"]
knowledge_base_description       = "Use this KB when the user asks about company policy."
enable_api_gateway               = true
api_throttling_rate_limit        = 500
api_throttling_burst_limit       = 1000
guardrail_id                     = "abc123def456"
guardrail_version                = "1"
log_retention_days               = 365
force_destroy                    = true
environment                      = "prod"
owner                            = "team-genai@example.com"
cost_center                      = "cc-1234"
project                          = "agentcore-tests"
tags                             = { Workload = "agent-platform" }
```

**Assertions**:
- Two Lambda action groups created — `length(aws_bedrockagent_agent_action_group.lambda) == 2`
- Weather tool has function_schema with one function — `length(aws_bedrockagent_agent_action_group.lambda["weather-tool"].function_schema[0].member_functions[0].functions) == 1`
- Weather tool function name — `aws_bedrockagent_agent_action_group.lambda["weather-tool"].function_schema[0].member_functions[0].functions[0].name == "get_weather"`
- Calendar tool uses inline api_schema payload — `aws_bedrockagent_agent_action_group.lambda["calendar-tool"].api_schema[0].payload != ""` `[plan-unknown]`
- Lambda executor wired for weather tool — `aws_bedrockagent_agent_action_group.lambda["weather-tool"].action_group_executor[0].lambda == "arn:aws:lambda:us-east-1:123456789012:function:weather"`
- One Lambda permission per action group — `length(aws_lambda_permission.bedrock_invoke) == 2`
- Lambda permission principal is bedrock — `aws_lambda_permission.bedrock_invoke["weather-tool"].principal == "bedrock.amazonaws.com"`
- Lambda permission action — `aws_lambda_permission.bedrock_invoke["weather-tool"].action == "lambda:InvokeFunction"`
- KB resource created — `length(aws_bedrockagent_knowledge_base.this) == 1`
- KB type is VECTOR — `aws_bedrockagent_knowledge_base.this[0].knowledge_base_configuration[0].type == "VECTOR"`
- KB embedding dimensions 1024 — `aws_bedrockagent_knowledge_base.this[0].knowledge_base_configuration[0].vector_knowledge_base_configuration[0].embedding_model_configuration[0].bedrock_embedding_model_configuration[0].dimensions == 1024`
- KB storage type is OPENSEARCH_SERVERLESS — `aws_bedrockagent_knowledge_base.this[0].storage_configuration[0].type == "OPENSEARCH_SERVERLESS"`
- AOSS collection type is VECTORSEARCH — `aws_opensearchserverless_collection.kb[0].type == "VECTORSEARCH"`
- AOSS encryption + network policies created — `length(aws_opensearchserverless_security_policy.encryption) == 1 && length(aws_opensearchserverless_security_policy.network) == 1`
- AOSS data access policy created — `length(aws_opensearchserverless_access_policy.kb) == 1`
- KB S3 data source bucket arn — `aws_bedrockagent_data_source.this[0].data_source_configuration[0].s3_configuration[0].bucket_arn == "arn:aws:s3:::test-corpus-bucket"`
- KB chunking strategy FIXED_SIZE — `aws_bedrockagent_data_source.this[0].vector_ingestion_configuration[0].chunking_configuration[0].chunking_strategy == "FIXED_SIZE"`
- KB data deletion policy RETAIN — `aws_bedrockagent_data_source.this[0].data_deletion_policy == "RETAIN"`
- KB association created — `length(aws_bedrockagent_agent_knowledge_base_association.this) == 1`
- KB association description matches input — `aws_bedrockagent_agent_knowledge_base_association.this[0].description == "Use this KB when the user asks about company policy."`
- KB association draft version — `aws_bedrockagent_agent_knowledge_base_association.this[0].agent_version == "DRAFT"`
- AOSS DAP wait timer present — `length(time_sleep.wait_aoss_dap) == 1 && time_sleep.wait_aoss_dap[0].create_duration == "60s"`
- API GW HTTP API protocol — `aws_apigatewayv2_api.this[0].protocol_type == "HTTP"`
- API stage auto_deploy on — `aws_apigatewayv2_stage.default[0].auto_deploy == true`
- API stage default name — `aws_apigatewayv2_stage.default[0].name == "$default"`
- API throttle rate limit applied — `aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_rate_limit == 500`
- API throttle burst limit applied — `aws_apigatewayv2_stage.default[0].default_route_settings[0].throttling_burst_limit == 1000`
- API access log destination is module log group — `aws_apigatewayv2_stage.default[0].access_log_settings[0].destination_arn != null` `[plan-unknown]`
- API integration type AWS_PROXY — `aws_apigatewayv2_integration.lambda[0].integration_type == "AWS_PROXY"`
- API integration payload format 2.0 — `aws_apigatewayv2_integration.lambda[0].payload_format_version == "2.0"`
- API integration timeout 30000ms — `aws_apigatewayv2_integration.lambda[0].timeout_milliseconds == 30000`
- API route is unauthenticated by default — `aws_apigatewayv2_route.invoke[0].authorization_type == "NONE"`
- API route key — `aws_apigatewayv2_route.invoke[0].route_key == "POST /invoke"`
- Invoker Lambda runtime — `aws_lambda_function.invoker[0].runtime == "python3.12"`
- Invoker Lambda has X-Ray active tracing — `aws_lambda_function.invoker[0].tracing_config[0].mode == "Active"`
- Invoker Lambda log group exists — `length(aws_cloudwatch_log_group.lambda) == 1`
- API access log group exists — `length(aws_cloudwatch_log_group.apigw_access) == 1`
- All log groups use 365-day retention — `aws_cloudwatch_log_group.agent.retention_in_days == 365`
- Lambda log group uses 365-day retention — `aws_cloudwatch_log_group.lambda[0].retention_in_days == 365`
- API access log group uses 365-day retention — `aws_cloudwatch_log_group.apigw_access[0].retention_in_days == 365`
- Guardrail bound to agent — `aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_identifier == "abc123def456"`
- Guardrail version pinned to numeric — `aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "1"`
- Force destroy propagates to action groups — `aws_bedrockagent_agent_action_group.lambda["weather-tool"].skip_resource_in_use_check == true`
- Custom tag merged — `aws_bedrockagent_agent.this.tags["Workload"] == "agent-platform"`
- Required environment tag still present — `aws_bedrockagent_agent.this.tags["Environment"] == "prod"`
- Idle session TTL respected — `aws_bedrockagent_agent.this.idle_session_ttl_in_seconds == 1800`
- Alias name is `prod` — `aws_bedrockagent_agent_alias.this.agent_alias_name == "prod"`

#### Scenario: Feature Interactions (edge cases)

**Purpose**: Verify non-obvious combinations of feature toggles produce correct behavior.
**Command**: `plan` (mock providers)

**Sub-scenario: Code interpreter disabled**
**Inputs**:
```hcl
agent_name              = "test"
instruction             = "<minimum-40-char instruction string used here for validation>"
enable_code_interpreter = false
environment             = "test"
owner                   = "x@y.z"
cost_center             = "c"
project                 = "p"
```
**Assertions**:
- No code interpreter action group created — `length(aws_bedrockagent_agent_action_group.code_interpreter) == 0`
- Agent still created — `aws_bedrockagent_agent.this.agent_name == "test"`
- Time sleep dependency still satisfied — `time_sleep.wait_after_prepare.create_duration == "10s"`

**Sub-scenario: Lambda action groups without code interpreter**
**Inputs**:
```hcl
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
environment = "test"; owner = "x@y.z"; cost_center = "c"; project = "p"
```
**Assertions**:
- One Lambda action group, zero code interpreter — `length(aws_bedrockagent_agent_action_group.lambda) == 1 && length(aws_bedrockagent_agent_action_group.code_interpreter) == 0`
- Lambda permission still required for the single tool — `length(aws_lambda_permission.bedrock_invoke) == 1`

**Sub-scenario: API Gateway enabled without knowledge base**
**Inputs**:
```hcl
agent_name        = "test"; instruction = "<minimum-40-char instruction string used here for validation>"
enable_api_gateway = true; enable_knowledge_base = false
environment = "test"; owner = "x@y.z"; cost_center = "c"; project = "p"
```
**Assertions**:
- API Gateway resources created — `length(aws_apigatewayv2_api.this) == 1`
- Invoker Lambda created — `length(aws_lambda_function.invoker) == 1`
- KB-side resources NOT created — `length(aws_bedrockagent_knowledge_base.this) == 0 && length(aws_opensearchserverless_collection.kb) == 0`
- KB association NOT created — `length(aws_bedrockagent_agent_knowledge_base_association.this) == 0`

**Sub-scenario: Knowledge base enabled without API Gateway**
**Inputs**:
```hcl
agent_name                   = "test"; instruction = "<minimum-40-char instruction string used here for validation>"
enable_knowledge_base        = true
knowledge_base_s3_bucket_arn = "arn:aws:s3:::corpus"
enable_api_gateway           = false
environment = "test"; owner = "x@y.z"; cost_center = "c"; project = "p"
```
**Assertions**:
- KB created — `length(aws_bedrockagent_knowledge_base.this) == 1`
- KB association created — `length(aws_bedrockagent_agent_knowledge_base_association.this) == 1`
- AOSS DAP wait timer present — `length(time_sleep.wait_aoss_dap) == 1`
- API GW resources NOT created — `length(aws_apigatewayv2_api.this) == 0`
- Invoker Lambda NOT created — `length(aws_lambda_function.invoker) == 0`

**Sub-scenario: Bring-your-own KMS key**
**Inputs**:
```hcl
agent_name  = "test"; instruction = "<minimum-40-char instruction string used here for validation>"
kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
environment = "test"; owner = "x@y.z"; cost_center = "c"; project = "p"
```
**Assertions**:
- Module-created KMS key NOT present — `length(aws_kms_key.this) == 0`
- Module-created KMS alias NOT present — `length(aws_kms_alias.this) == 0`
- Agent uses BYO key — `aws_bedrockagent_agent.this.customer_encryption_key_arn == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"`
- Log group still encrypted with BYO key — `aws_cloudwatch_log_group.agent.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"`

**Sub-scenario: Guardrail bound without enabling other features**
**Inputs**:
```hcl
agent_name = "test"; instruction = "<minimum-40-char instruction string used here for validation>"
guardrail_id      = "gd123abc"; guardrail_version = "2"
environment = "test"; owner = "x@y.z"; cost_center = "c"; project = "p"
```
**Assertions**:
- Guardrail block populated on agent — `aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_identifier == "gd123abc"`
- Guardrail version pinned — `aws_bedrockagent_agent.this.guardrail_configuration[0].guardrail_version == "2"`
- Inline policy includes ApplyGuardrail statement — `length(regexall("bedrock:ApplyGuardrail", aws_iam_role_policy.agent.policy)) > 0`

#### Scenario: Validation Boundaries (accept)

**Purpose**: Verify validation rules accept values at the valid boundary.
**Command**: `plan` (mock providers)

**Boundary-pass cases**:
- `agent_name`: `"a"` (length 1, regex pass) -> accepted
- `agent_name`: 100-character string of `[A-Za-z0-9_-]` -> accepted
- `instruction`: 40-character string -> accepted (minimum)
- `instruction`: 20000-character string -> accepted (maximum)
- `idle_session_ttl_seconds`: `60` -> accepted (minimum)
- `idle_session_ttl_seconds`: `3600` -> accepted (maximum)
- `log_retention_days`: `1` -> accepted (smallest CloudWatch-allowed value)
- `log_retention_days`: `90` -> accepted (default, mid-range)
- `log_retention_days`: `3653` -> accepted (largest CloudWatch-allowed value, ~10y)
- `wait_after_prepare_seconds`: `0` -> accepted (disable timer)
- `wait_after_prepare_seconds`: `120` -> accepted (maximum)
- `api_throttling_rate_limit`: `1` -> accepted (smallest positive)
- `api_throttling_rate_limit`: `10000` -> accepted (maximum)
- `api_throttling_burst_limit`: `1` -> accepted (smallest positive)
- `api_throttling_burst_limit`: `10000` -> accepted (maximum)
- `environment`: `"sandbox"` -> accepted (one of the validation set)
- `kms_key_arn`: `""` -> accepted (empty triggers module-created key)
- `kms_key_arn`: `"arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/abcd"` -> accepted (GovCloud partition pattern matches)
- `knowledge_base_s3_bucket_arn`: when `enable_knowledge_base = false`, empty `""` -> accepted (no requirement when KB disabled)
- `guardrail_id`: `""` -> accepted (no guardrail bound)
- `guardrail_version`: `"DRAFT"` when `guardrail_id != ""` -> accepted (with documentation warning)
- `guardrail_version`: `"42"` when `guardrail_id != ""` -> accepted (numeric version)

Each case becomes a `run` block with `command = plan` and an assert that the relevant resource is created (e.g., `aws_bedrockagent_agent.this.agent_name != ""`).

#### Scenario: Validation Errors (reject)

**Purpose**: Verify input validation rejects bad inputs
**Command**: `plan` (mock providers)

**Expect error cases** (each uses `expect_failures = [var.<name>]`):
- `agent_name = ""` -> length validation rejects
- `agent_name = "has spaces"` -> regex rejects (space not in character class)
- `agent_name = "<101-char string>"` -> length max rejects
- `instruction = "too short"` -> 40-char minimum rejects
- `instruction = "<20001-char string>"` -> 20000-char maximum rejects
- `idle_session_ttl_seconds = 30` -> below 60 minimum rejects
- `idle_session_ttl_seconds = 7200` -> above 3600 maximum rejects
- `log_retention_days = 45` -> not in CloudWatch-allowed list rejects
- `log_retention_days = 0` -> not in CloudWatch-allowed list rejects
- `wait_after_prepare_seconds = -1` -> below 0 rejects
- `wait_after_prepare_seconds = 200` -> above 120 rejects
- `api_throttling_rate_limit = 0` -> not strictly positive rejects
- `api_throttling_rate_limit = 20000` -> above 10000 rejects
- `environment = "production"` -> not in `["dev","staging","prod","sandbox","test"]` rejects
- `owner = ""` -> length minimum rejects
- `cost_center = ""` -> length minimum rejects
- `project = ""` -> length minimum rejects
- `kms_key_arn = "not-an-arn"` -> regex rejects
- `knowledge_base_s3_bucket_arn = "not-an-arn"` with `enable_knowledge_base = true` -> regex + non-empty rejects
- `enable_knowledge_base = true` with `knowledge_base_s3_bucket_arn = ""` -> custom validation in `variable` block rejects ("required when knowledge base enabled")
- `guardrail_id = "INVALID-CASE"` -> regex `[a-z0-9]+` rejects uppercase + dash
- `guardrail_version = "v1"` with `guardrail_id != ""` -> regex `[0-9]+|DRAFT` rejects
- `action_group_definitions = { "bad" = { description = "x", lambda_arn = "arn:..." } }` (neither `api_schema` nor `function_schema`) -> custom validation rejects
- `action_group_definitions = { "bad" = { description = "x", lambda_arn = "arn:...", api_schema = { payload = "y", s3 = { s3_bucket_name = "b", s3_object_key = "k" } } } }` (both `payload` AND `s3` set) -> custom validation rejects

### Acceptance Tests

#### Scenario: Plan Verification

**Purpose**: Verify plan output with real provider APIs — validates computed attributes, ARN formats, and provider-resolved references that unit tests cannot check
**Command**: `plan` (real providers)

**Inputs** (same as Secure Defaults plus an in-region foundation model):
```hcl
agent_name       = "acceptance-test-agent"
instruction      = "You are a helpful assistant. Answer user questions clearly and concisely. Use the code interpreter only when computation is required."
foundation_model = "anthropic.claude-3-5-sonnet-20241022-v2:0"
environment      = "test"
owner            = "team-genai@example.com"
cost_center      = "cc-1234"
project          = "agentcore-tests"
```

**Assertions** (each marked `# acceptance`):
- Agent ARN format — `can(regex("^arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:agent/[A-Z0-9]+$", aws_bedrockagent_agent.this.agent_arn))`
- Agent alias ARN format — `can(regex("^arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:agent-alias/[A-Z0-9]+/[A-Z0-9]+$", aws_bedrockagent_agent_alias.this.agent_alias_arn))`
- KMS key ARN format — `can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", aws_kms_key.this[0].arn))`
- Log group ARN format — `can(regex("^arn:aws:logs:[a-z0-9-]+:[0-9]{12}:log-group:/aws/bedrock/agents/acceptance-test-agent:.*$", aws_cloudwatch_log_group.agent.arn))`
- IAM role ARN format — `can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", aws_iam_role.agent.arn))`
- Inline policy contains foundation model ARN — `length(regexall("foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0", aws_iam_role_policy.agent.policy)) > 0`
- Inline policy scopes lambda action — when no action groups, `length(regexall("lambda:InvokeFunction", aws_iam_role_policy.agent.policy)) == 0`
- Trust policy includes confused-deputy guard — `length(regexall("aws:SourceAccount", aws_iam_role.agent.assume_role_policy)) > 0`

### Integration Tests

#### Scenario: End-to-End

**Purpose**: Verify resources are created, configured correctly, and functional in AWS
**Command**: `apply` (real providers)

**Inputs** (realistic deployment with KB and API GW disabled to keep cost minimal):
```hcl
agent_name       = "integration-test-agent"
instruction      = "You are a helpful assistant. Answer user questions clearly and concisely. Use the code interpreter only when computation is required."
foundation_model = "anthropic.claude-3-5-sonnet-20241022-v2:0"
environment      = "test"
owner            = "team-genai@example.com"
cost_center      = "cc-1234"
project          = "agentcore-tests"
force_destroy    = true
```

**Assertions** (each marked `# integration`):
- Agent reaches PREPARED state — `aws_bedrockagent_agent.this.agent_status == "PREPARED"`
- Agent version is numeric (not DRAFT) post-prepare — `can(regex("^[0-9]+$", aws_bedrockagent_agent.this.agent_version))`
- Alias resolves — `aws_bedrockagent_agent_alias.this.agent_alias_id != ""`
- KMS key is enabled — `aws_kms_key.this[0].is_enabled == true`
- Log group exists in CloudWatch — `aws_cloudwatch_log_group.agent.id != ""`
- Output `agent_alias_arn` is populated — `output.agent_alias_arn != null && output.agent_alias_arn != ""`
- Output `kms_key_arn` is populated — `output.kms_key_arn != null && output.kms_key_arn != ""`
- Output `knowledge_base_id` is null when KB disabled — `output.knowledge_base_id == null`
- Output `api_endpoint` is null when API GW disabled — `output.api_endpoint == null`

---

## 6. Implementation Checklist

- [x] **A: Scaffold** — Create `versions.tf` (`required_version >= 1.14`, `aws >= 5.50`, `time >= 0.11`, `opensearch >= 2.3`), `data.tf` (`aws_caller_identity`, `aws_partition`, `aws_region`), all variables in `variables.tf` with full validation, `locals.tf` (`required_tags`, derived ARNs, computed flags), all outputs in `outputs.tf` with `try(...,null)` for conditional ones, and empty-section placeholders in `main.tf`.
- [x] **B: Security core** — Implement `aws_kms_key.this` + `aws_kms_alias.this` (conditional on empty `kms_key_arn`) with rotation + key policy, `aws_cloudwatch_log_group.agent` with KMS + retention, `aws_iam_role.agent` with confused-deputy trust, and `aws_iam_role_policy.agent` with the dynamically-built inline policy (foundation model ARN, log group ARN, KMS ARN with `kms:ViaService`, X-Ray, conditional action-group Lambda ARNs, conditional KB ARN, conditional guardrail ARN).
- [x] **C: Agent runtime** — Implement `aws_bedrockagent_agent.this` (`prepare_agent = false`, `customer_encryption_key_arn`, conditional `guardrail_configuration` block), `aws_bedrockagent_agent_action_group.code_interpreter` (`for_each` over `var.enable_code_interpreter ? toset(["this"]) : toset([])`), `time_sleep.wait_after_prepare`, and `aws_bedrockagent_agent_alias.this` with pinned `routing_configuration.agent_version` + `lifecycle { ignore_changes = [routing_configuration] }`.
- [ ] **D: Lambda action groups** — Implement `aws_bedrockagent_agent_action_group.lambda` and `aws_lambda_permission.bedrock_invoke`, both `for_each = var.action_group_definitions`. Each action group uses dynamic blocks for `api_schema` (payload OR s3 sub-block) vs `function_schema`, `depends_on = [aws_lambda_permission.bedrock_invoke[each.key]]`. Add `time_sleep.wait_after_prepare` `depends_on` to include `aws_bedrockagent_agent_action_group.lambda`.
- [ ] **E: Knowledge base** — Implement `aws_iam_role.kb` + `aws_iam_role_policy.kb`, `aws_opensearchserverless_security_policy.encryption`/`network`, `aws_opensearchserverless_collection.kb`, `aws_opensearchserverless_access_policy.kb`, `time_sleep.wait_aoss_dap`, `opensearch_index.kb` (with k-NN field mapping), `aws_bedrockagent_knowledge_base.this`, `aws_bedrockagent_data_source.this`, `aws_bedrockagent_agent_knowledge_base_association.this` — all gated on `count = var.enable_knowledge_base ? 1 : 0`. Append KB ARN to agent inline policy in `B`.
- [ ] **F: API Gateway** — Implement `files/invoker/index.py` (Python 3.12 invoker calling `bedrock-agent-runtime:InvokeAgent`), `archive_file.invoker_zip` data source, `aws_iam_role.lambda` + `aws_iam_role_policy.lambda`, `aws_cloudwatch_log_group.lambda`, `aws_lambda_function.invoker` (X-Ray Active), `aws_apigatewayv2_api.this`, `aws_apigatewayv2_integration.lambda`, `aws_apigatewayv2_route.invoke`, `aws_cloudwatch_log_group.apigw_access`, `aws_apigatewayv2_stage.default` (throttling + access log JSON format), `aws_lambda_permission.apigw_invoke` — all gated on `count = var.enable_api_gateway ? 1 : 0`.
- [ ] **G: Examples** — `examples/basic/main.tf` (provider config, minimal inputs: agent + code interpreter only) and `examples/complete/main.tf` (provider config, all features enabled including BYO KMS key created in the example, KB pointing at an example bucket created in the example, API GW with consumer-attached JWT authorizer demo).
- [ ] **H: Tests + polish** — Five `.tftest.hcl` files (`unit_basic`, `unit_complete`, `unit_edge_cases`, `unit_validation` covering both boundary-pass and `expect_failures`, `acceptance` with `# acceptance` markers, `integration` with `# integration` markers), then `terraform fmt -recursive`, `terraform validate`, `tflint`, `trivy config .`, `terraform-docs` to regenerate `README.md`, populate `CHANGELOG.md` with v1.0.0 entry.

---

## 7. Open Questions

- **[CONSTITUTION DEVIATION] X-Ray IAM resource scope**: Constitution §3.2 requires "Specific resource ARNs. No wildcards (`*`) unless unavoidable with documented justification." The agent execution role's inline policy contains exactly one wildcard: `Resource: "*"` on the `xray:PutTraceSegments` and `xray:PutTelemetryRecords` actions. AWS X-Ray does NOT support resource-level permissions for these two actions per the AWS X-Ray IAM documentation (`docs.aws.amazon.com/xray/latest/devguide/security_iam_service-with-iam.html`); using a specific resource is not possible. The same wildcard appears on the optional invoker Lambda's execution role for the same reason. Justification is documented as an inline code comment `# X-Ray does not support resource-level permissions; see AWS X-Ray IAM docs.` This is the ONLY wildcard in the module's generated IAM policies and Trivy `AVD-AWS-0057` will not fire on it.

- **[DEFERRED] Bedrock Guardrail creation**: v1 binds a consumer-supplied `guardrail_id` only. v2 may add `enable_guardrails` + `aws_bedrock_guardrail.this` (content filters at HIGH for SEXUAL/VIOLENCE/HATE/INSULTS/MISCONDUCT/PROMPT_ATTACK) + `aws_bedrock_guardrail_version.this` per the security research. Punted to keep v1 surface area manageable and because guardrails are often centrally managed.

- **[DEFERRED] Account/region-singleton invocation logging**: `aws_bedrock_model_invocation_logging_configuration` is a per-(account, region) singleton. Multiple module instances all managing it would clobber each other on apply. v1 omits it; consumers configure invocation logging at the account level (out of module scope). Document in README.

- **[DEFERRED] Aurora pgvector / Pinecone / MongoDB knowledge base backends**: v1 only supports OpenSearch Serverless. The `vector_store_type` variable is intentionally NOT exposed in v1 to avoid implying support; reserve for a v2 expansion that adds `vector_store_type = "AURORA_POSTGRESQL"` with the full RDS cluster lifecycle as a separate code path.

- **[DEFERRED] Bedrock AgentCore (containerized runtime) sibling module**: AWS ships a separate "Bedrock AgentCore" product (`aws_bedrockagentcore_*` resources) for LangGraph/CrewAI/Strands containerized agents. That is a distinct abstraction (container image + network configuration + protocol configuration) and warrants a separate sibling module rather than mixing into this one. Documented in research-bedrock-agent-resources.md Terminology Note.
