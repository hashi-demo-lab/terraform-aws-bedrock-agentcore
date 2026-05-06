## Research: Map the AWS Terraform provider resources required to build a complete AWS Bedrock Agent module — agent runtime, alias, action groups (code interpreter + Lambda-backed), and lifecycle relationships

### Decision

Build the module on the classic **Bedrock Agents** resource family (`aws_bedrockagent_agent`, `aws_bedrockagent_agent_alias`, `aws_bedrockagent_agent_action_group`) using `for_each`-driven action group composition. Inject the AWS-managed code interpreter via a dedicated action group whose `parent_action_group_signature = "AMAZON.CodeInterpreter"`. Disable the resource-level `prepare_agent` flag on the agent and instead rely on the action-group-level `prepare_agent` (default `true`) to ensure all action groups are attached before the DRAFT version is prepared, then create the alias against the prepared `agent_version`. Pair the agent with `aws_iam_role` + `aws_iam_role_policy`, an `aws_kms_key` for at-rest encryption, and a `aws_cloudwatch_log_group` + `aws_bedrock_model_invocation_logging_configuration` (or `aws_cloudwatch_log_delivery_*`) for invocation-log capture. X-Ray tracing is enabled implicitly when an alias receives traffic — no Terraform-managed `aws_xray_*` resource is required for the agent itself.

### Terminology Note

The feature name is `001-bedrock-agentcore`, but the resources called out in the question (`aws_bedrockagent_agent`, `aws_bedrockagent_agent_alias`, `aws_bedrockagent_agent_action_group`, `parent_action_group_signature = "AMAZON.CodeInterpreter"`) all live in the classic **Bedrock Agents** service (subcategory "Bedrock Agents" in the provider). AWS also ships a *separate* product called **Amazon Bedrock AgentCore** (a containerized serverless runtime for LangGraph/CrewAI/Strands agents) with its own resource family `aws_bedrockagentcore_*` (subcategory "Bedrock AgentCore"). These are distinct services. This research targets the classic Bedrock Agents resources as called out in the question; the AgentCore-specific resources are listed in the "Alternatives Considered" section for completeness so the orchestrator can confirm intent before design.

### Resources Identified

#### Primary Resource

- **`aws_bedrockagent_agent`** — the agent itself. Holds the foundation model, instruction prompt, KMS key, idle session TTL, and (optionally) prompt overrides, guardrails, memory.

#### Supporting Resources

- **`aws_bedrockagent_agent_alias`** — stable invocation handle pinned to a numeric agent version (e.g. `1`, `2`) instead of the mutable `DRAFT`.
- **`aws_bedrockagent_agent_action_group`** — created with `for_each`. Three modes are supported by the schema and all three should be expressible from a single map input:
  1. **Built-in code interpreter** — `parent_action_group_signature = "AMAZON.CodeInterpreter"`; description, api_schema, action_group_executor MUST be omitted (AWS API requirement).
  2. **Lambda-backed (OpenAPI inline)** — `action_group_executor.lambda = <fn_arn>` plus `api_schema.payload = <yaml-or-json>`.
  3. **Lambda-backed (OpenAPI from S3)** — `action_group_executor.lambda = <fn_arn>` plus `api_schema.s3.{s3_bucket_name,s3_object_key}`.
  4. **Lambda-backed (function schema, no OpenAPI)** — `action_group_executor.lambda = <fn_arn>` plus `function_schema.member_functions.functions[*]` with `parameters` (each parameter uses the historically-named `map_block_key` for parameter name).
  5. **Return-of-control** (no Lambda) — `action_group_executor.custom_control = "RETURN_CONTROL"` + an `api_schema`.
  6. **AMAZON.UserInput** (clarification) — `parent_action_group_signature = "AMAZON.UserInput"`, all other content fields blank.
- **`aws_iam_role`** + **`aws_iam_role_policy`** — service role for `bedrock.amazonaws.com` with conditions `aws:SourceAccount` and `aws:SourceArn` scoped to `arn:<partition>:bedrock:<region>:<account>:agent/*`. Required permissions: `bedrock:InvokeModel` for the foundation model ARN; if KMS encrypting the agent, `kms:Decrypt` / `kms:GenerateDataKey` on the customer key; if S3 schemas are used, `s3:GetObject` on the schema bucket; if guardrails are used, `bedrock:ApplyGuardrail`.
- **`aws_lambda_permission`** (`statement_id_prefix = "AllowBedrockInvoke-"`, `action = "lambda:InvokeFunction"`, `principal = "bedrock.amazonaws.com"`, `source_arn = aws_bedrockagent_agent.this.agent_arn`) — REQUIRED for every Lambda-backed action group; otherwise invocations 403 at runtime even though Terraform applies cleanly.
- **`aws_kms_key`** + **`aws_kms_alias`** (created by module OR consumer-supplied via `customer_encryption_key_arn`) — encrypts agent metadata, prompt overrides, and session state at rest. Key policy must allow `bedrock.amazonaws.com` service principal `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey` with `kms:EncryptionContext:aws:bedrock:arn` condition pinned to the agent ARN.
- **`aws_cloudwatch_log_group`** — destination for invocation logs / agent traces. KMS-encrypted, retention configurable.
- **`aws_bedrock_model_invocation_logging_configuration`** *(account/region-singleton)* — enables CloudWatch / S3 logging of `InvokeAgent` payloads. Note: this is a per-(account, region) singleton; the module should expose a `manage_invocation_logging` toggle (default `false`) to avoid clobbering account-wide settings when multiple agents coexist.
- **`aws_cloudwatch_log_delivery_source` + `aws_cloudwatch_log_delivery_destination` + `aws_cloudwatch_log_delivery`** *(optional, newer pattern)* — vended-logs delivery if the consumer prefers per-resource log delivery over the singleton config.

#### Resources NOT Required

- **No `aws_xray_*` resource** — X-Ray tracing for Bedrock agents is part of the agent trace stream; it is collected automatically when traces are requested in the `InvokeAgent` call (`enableTrace = true`) and rendered in the X-Ray service map without a Terraform-managed sampling rule. The module surfaces tracing as an output flag, not a resource.
- **No provider block** — the module inherits providers from the consumer per the project constitution.

### Key Arguments per Primary Resource

#### `aws_bedrockagent_agent` (provider 6.x)

| Argument | Required | Notes |
|---|---|---|
| `agent_name` | Yes | Used for the agent's stable name. |
| `agent_resource_role_arn` | Yes | Service role ARN. |
| `foundation_model` | Yes | Model id like `anthropic.claude-3-5-sonnet-20241022-v2:0`. |
| `instruction` | Conditionally required | REQUIRED whenever `prepare_agent = true` (the default). 40–20 000 chars. |
| `idle_session_ttl_in_seconds` | No | 60–3600. Default 600. |
| `customer_encryption_key_arn` | No | KMS CMK ARN for at-rest encryption — secure default is "create one inside the module" or accept an external ARN; never leave null in regulated envs. |
| `description` | No | Free text. |
| `prepare_agent` | No | Default `true`. Triggers `PrepareAgent` API after every change to the agent's own attributes. **Gotcha**: it does NOT re-prepare on action-group changes — the per-action-group `prepare_agent` field handles those. Set this to `false` on the agent and let action groups drive prepare to avoid double-prepare during initial create. |
| `skip_resource_in_use_check` | No | Set `true` to allow `terraform destroy` while aliases exist. |
| `agent_collaboration` | No | `SUPERVISOR` / `SUPERVISOR_ROUTER` / `DISABLED` — multi-agent collaboration. |
| `guardrail_configuration` | No | Block: `guardrail_identifier` + `guardrail_version`. |
| `memory_configuration` | No | Block: `enabled_memory_types` (e.g., `["SESSION_SUMMARY"]`), `storage_days` (0–30), `session_summary_configuration.max_recent_sessions`. |
| `prompt_override_configuration` | No | Override pre/post/orchestration/KB-response-generation prompts. |
| `tags` | No | Standard. |

#### `aws_bedrockagent_agent_alias`

| Argument | Required | Notes |
|---|---|---|
| `agent_alias_name` | Yes | Stable name like `prod`, `live`. |
| `agent_id` | Yes | **ForceNew** — changing it recreates the alias. Pull from `aws_bedrockagent_agent.this.agent_id` (NOT `.id`). |
| `description` | No | |
| `routing_configuration.agent_version` | No | Pin to a specific numeric version. If omitted, AWS auto-creates a new numeric version each apply, which churns the alias. **Pattern from Flaconi module**: pin to `aws_bedrockagent_agent.this.agent_version` and `lifecycle { ignore_changes = [routing_configuration] }` so subsequent agent updates do not force alias re-targeting. |
| `routing_configuration.provisioned_throughput` | No | ARN of provisioned throughput (provisioned-capacity customers only). |
| `tags` | No | |

#### `aws_bedrockagent_agent_action_group`

| Argument | Required | Notes |
|---|---|---|
| `action_group_name` | Yes | Unique within agent. |
| `agent_id` | Yes | |
| `agent_version` | Yes | Only valid value: `"DRAFT"`. Action groups can only be attached to the working draft; numeric versions are immutable snapshots. |
| `action_group_executor` | Required for non-built-in groups; MUST be omitted for `parent_action_group_signature` groups | Block with EITHER `lambda = <fn_arn>` OR `custom_control = "RETURN_CONTROL"`. |
| `parent_action_group_signature` | Optional, mutually exclusive with executor/schema | `AMAZON.UserInput`, `AMAZON.CodeInterpreter`, or computer-use values (`ANTHROPIC.Computer`, `ANTHROPIC.Bash`, `ANTHROPIC.TextEditor` — beta). |
| `api_schema` | Optional | Block: `payload` (inline OpenAPI YAML/JSON) OR `s3.{s3_bucket_name,s3_object_key}` — exactly one. |
| `function_schema` | Optional | Block: `member_functions.functions[*]` — alternative to OpenAPI for simple function declarations. Each `parameters` block uses `map_block_key` for the parameter name (legacy schema artefact). |
| `description` | Optional | MUST be omitted for `AMAZON.CodeInterpreter` and `AMAZON.UserInput`. |
| `action_group_state` | Optional | `ENABLED` / `DISABLED`. |
| `prepare_agent` | Optional | Default `true` — triggers `PrepareAgent` after this group is reconciled. **This is the right knob for prepare ordering**; if you have N action groups all with default `true`, AWS prepares N times. Acceptable for safety; can be optimised by setting `prepare_agent = false` on all-but-the-last group via a `for_each` indexing trick if creation time matters. |
| `skip_resource_in_use_check` | Optional | Default `false`. Set `true` to allow destroy while alias references the version. |

### Key Outputs (Computed Attributes)

- `aws_bedrockagent_agent.this`:
  - `agent_id` (`string`) — short identifier (e.g., `GGRRAED6JP`). Use this in cross-resource refs.
  - `agent_arn` (`string`) — full ARN.
  - `agent_version` (`string`) — current prepared version (`DRAFT` or numeric).
  - `prepared_at` (`string`) — RFC3339 timestamp.
- `aws_bedrockagent_agent_alias.this`:
  - `agent_alias_id` (`string`)
  - `agent_alias_arn` (`string`)
  - `id` (`string`) — composite `<alias_id>,<agent_id>`.
- `aws_bedrockagent_agent_action_group.this[k]`:
  - `action_group_id` (`string`)
  - `id` (`string`) — composite `<group_id>,<agent_id>,<agent_version>`.

### Lifecycle Ordering & Explicit Dependencies

The implicit dependency graph derived from `agent_id` references is correct in most cases, but two relationships need explicit handling:

1. **Action groups → Agent**: Implicit via `agent_id = aws_bedrockagent_agent.this.agent_id`. No `depends_on` needed.
2. **Lambda permission → Action group**: The `aws_lambda_permission` for `bedrock.amazonaws.com` SHOULD exist before the action group is created; otherwise the first `InvokeAgent` call after apply 403s. Add `depends_on = [aws_lambda_permission.bedrock_invoke[<key>]]` on each Lambda-backed action group, or order the resources with implicit refs (use `aws_lambda_permission.bedrock_invoke[k].statement_id` in a `function_arn`-side string concatenation — cleaner to use explicit `depends_on`).
3. **Alias → Action groups**: An alias should only be created after all action groups are attached AND the draft has been prepared. The cleanest pattern (from the Flaconi module) is:
   - Set `prepare_agent = false` on `aws_bedrockagent_agent`.
   - Let each `aws_bedrockagent_agent_action_group` keep its default `prepare_agent = true` — the LAST one to apply triggers the final prepare.
   - Add `depends_on = [aws_bedrockagent_agent_action_group.this]` on the alias so it waits for the entire `for_each` set.
   - Set `routing_configuration.agent_version = aws_bedrockagent_agent.this.agent_version` and `lifecycle { ignore_changes = [routing_configuration] }`.
4. **`time_sleep` between agent and alias** (Flaconi pattern): a 10-second `time_sleep.wait_after_prepare` resource is sometimes needed because the `agent_version` attribute is computed from the last prepare, which AWS reports as complete a beat before the new version is actually addressable from `CreateAgentAlias`. This is a known eventual-consistency wart — recommend including the time_sleep in the module behind a `wait_after_prepare_seconds` variable defaulting to `10`.
5. **Destroy ordering**: `aws_bedrockagent_agent_alias` blocks `aws_bedrockagent_agent` deletion unless `skip_resource_in_use_check = true` is set on the agent. Recommend `skip_resource_in_use_check = true` on action groups too, behind a `force_destroy` module variable.

### Prepare Behavior — Detailed

`prepare_agent` calls the `PrepareAgent` API which compiles the DRAFT agent into a callable runtime and bumps `agent_version`. Triggered when:
- `prepare_agent = true` AND any of: `instruction`, `foundation_model`, `prompt_override_configuration`, `guardrail_configuration`, `memory_configuration`, `agent_collaboration` change on the agent itself.
- `prepare_agent = true` (default) on a child `aws_bedrockagent_agent_action_group` when ANY action-group field changes.

Re-trigger gotchas:
- Editing only tags does NOT re-prepare.
- Editing the IAM role (e.g., adding a permission) does NOT re-prepare — but if the new permission is required for orchestration, you may need to taint the agent or temporarily flip `prepare_agent` to force re-prepare.
- Deleting an action group with `prepare_agent = true` re-prepares; deleting the LAST action group with the agent in a half-state can leave stale references — use `skip_resource_in_use_check = true` on action groups during destroy.

### Region Availability

- **Bedrock Agents control plane (`bedrock-agent.<region>.amazonaws.com`)** is available in: us-east-1, us-east-2, us-west-2, ap-southeast-1, ap-southeast-2, ap-northeast-1, ap-northeast-2, ca-central-1, eu-central-1, eu-west-1, eu-west-2, eu-west-3, ap-south-1, sa-east-1 (plus FIPS endpoints in us-east-1/us-west-2). Note: us-west-1 is NOT in the agents list even though base Bedrock is.
- **AMAZON.CodeInterpreter action group** is supported in a much narrower set: **us-east-1 (N. Virginia), us-west-2 (Oregon), eu-central-1 (Frankfurt)** only. Module should validate region against this set when `enable_code_interpreter = true` and either fail-fast with a clear error or warn.
- **Foundation model availability** varies per region — Claude 3.5 Sonnet v2 is in us-east-1/us-east-2/us-west-2/eu-central-1; Nova models are us-east-1 only at launch. Module should treat `foundation_model` as a string the consumer asserts is available; do not hard-code a default that breaks in some regions.
- **Bedrock AgentCore (the separate service)** is GA in fewer regions still — primarily us-east-1, us-west-2, ap-southeast-2, eu-central-1 — and has DIFFERENT resources (`aws_bedrockagentcore_*`).

### Rationale

- **Why classic `aws_bedrockagent_agent` over `aws_bedrockagentcore_agent_runtime`**: The question explicitly names `aws_bedrockagent_agent` and the constituent attributes (`agent_name`, `foundation_model`, `instruction`, `idle_session_ttl_in_seconds`, `customer_encryption_key_arn`, `parent_action_group_signature = "AMAZON.CodeInterpreter"`) — all of which exist only in the Bedrock Agents resource family, not in AgentCore. AgentCore Runtime is a containerized execution model (`agent_runtime_artifact.container_configuration.container_uri`, `network_configuration`, `protocol_configuration.server_protocol = "MCP"`) — a fundamentally different abstraction.
- **Why `for_each` for action groups, not separate variables**: The Flaconi reference module hard-codes only the four prompt-override slots and exposes ad-hoc variables for a single optional KB association — it does not handle multiple action groups well. CloudPediaAI uses an `awscc_bedrock_agent.agent` mega-resource that bundles everything but loses fine-grained Terraform plan visibility. A `for_each` over a `map(object({...}))` input is the pattern from the public `terraform-aws-modules` ecosystem (e.g., `terraform-aws-modules/iam/aws//modules/iam-policy` uses similar map-driven interfaces) and gives consumers single-tool, multi-tool, and code-interpreter-only configurations from one variable.
- **Why a per-module-instance KMS key by default**: AWS docs explicitly call out that agents created without a CMK use AWS-owned keys, which CIS Bedrock benchmark v1.0 control 2.1 flags as non-compliant for production. The module should accept `kms_key_arn` and create one if not supplied (`var.create_kms_key`).
- **Why pin alias to `agent_version` with `ignore_changes`**: The Flaconi module discovered (and codified in `lifecycle { ignore_changes = [routing_configuration] }`) that without ignore_changes, every `terraform apply` that touches the agent re-points the alias and creates a perceived churn even though no traffic-routing change is intended. Pinning at create time + ignoring subsequent changes is the right balance for a "stable invocation handle".

### Alternatives Considered

| Alternative | Why Not |
|---|---|
| `aws_bedrockagentcore_agent_runtime` (containerized) | Different product, requires an ECR image or S3 zip + `network_configuration`, `protocol_configuration`. The question is about model+instruction agents with action groups, not container deployments. Document as a separate future module. |
| `awscc_bedrock_agent` (Cloud Control API) | Used by CloudPediaAI module. Cloud Control resources lag the AWS provider on schema completeness (no native `function_schema`, no `prompt_override_configuration`, no per-resource timeouts), and require a second provider in the consumer. Adds a provider dependency for no benefit. |
| Separate action-group resources (one Terraform resource per logical tool) | Inflexible — every new tool requires a module-source change. `for_each` lets consumers add tools by editing tfvars. |
| Inline `parent_action_group_signature` on the agent itself | Not a real schema option; code interpreter must be a child action group. |
| Manage `aws_bedrock_model_invocation_logging_configuration` always | This is an account/region SINGLETON. If two module instances both manage it, the second `apply` clobbers the first. Make it opt-in via `manage_invocation_logging = false` default. |
| Use `aws_xray_sampling_rule` for agent traces | Not how Bedrock traces work — traces are emitted into the agent trace stream and surfaced in X-Ray service maps automatically when `enableTrace=true` is set on `InvokeAgent`. No sampling-rule configuration is exposed to Terraform. |
| Pin `routing_configuration.agent_version` without `ignore_changes` | Causes alias churn on every agent apply; surprises consumers. The Flaconi pattern (pin once, ignore after) is the established pattern. |
| Set agent-level `prepare_agent = true` AND action-group-level `prepare_agent = true` | Causes double/triple prepares on initial create (one per agent change, one per action group). Set agent-level to `false` and rely on the last action-group apply to trigger the final prepare. |

### Sources

- AWS Provider docs (hashicorp/aws v6.43.0):
  - `aws_bedrockagent_agent`: https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/bedrockagent_agent.html.markdown
  - `aws_bedrockagent_agent_alias`: https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/bedrockagent_agent_alias.html.markdown
  - `aws_bedrockagent_agent_action_group`: https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/bedrockagent_agent_action_group.html.markdown
  - `aws_bedrockagentcore_agent_runtime` (separate AgentCore product, included for terminology disambiguation): https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/bedrockagentcore_agent_runtime.html.markdown
- AWS service docs:
  - Bedrock Agents code interpretation (AMAZON.CodeInterpreter signature & supported regions): https://docs.aws.amazon.com/bedrock/latest/userguide/agents-code-interpretation.html
  - `CreateAgentActionGroup` API (parent_action_group_signature valid values): https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_CreateAgentActionGroup.html
  - Service role for Bedrock Agents (IAM trust + permissions): https://docs.aws.amazon.com/bedrock/latest/userguide/security-iam-sr.html
  - Bedrock Agents endpoints (regional availability): https://docs.aws.amazon.com/general/latest/gr/bedrock.html
  - Bedrock model invocation logging (singleton config): https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html
  - Deploy and use a Bedrock agent (alias deployment): https://docs.aws.amazon.com/bedrock/latest/userguide/agents-deploy.html
  - Bedrock AgentCore overview (separate product): https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html
- Public registry modules studied:
  - `Flaconi/bedrock-agent/aws` v1.2.1 — source of the `time_sleep` pattern, the `lifecycle { ignore_changes = [routing_configuration] }` pattern on the alias, and the four-slot `prompt_override_configuration`. Notable gap: no first-class action-group support (KB-only). https://registry.terraform.io/modules/Flaconi/bedrock-agent/aws/latest
  - `CloudPediaAI/ai-agent/aws` v1.0.2 — uses `awscc_bedrock_agent` mega-resource. Studied as counterexample. https://registry.terraform.io/modules/CloudPediaAI/ai-agent/aws/latest
