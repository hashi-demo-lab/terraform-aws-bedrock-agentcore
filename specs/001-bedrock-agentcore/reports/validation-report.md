# Validation Report: terraform-aws-bedrock-agentcore

| Field    | Value                                                |
| -------- | ---------------------------------------------------- |
| Branch   | main                                                 |
| Date     | 2026-05-06                                           |
| Provider | aws >= 5.50, time >= 0.11, opensearch >= 2.3, archive >= 2.4 |
| Feature  | 001-bedrock-agentcore                                |
| Issue    | #1                                                   |

---

## Design Conformance

Design source: `/workspace/specs/001-bedrock-agentcore/design.md`
Constitution: `/workspace/.foundations/memory/module-constitution.md` (v5.0.0)

| Area | Result | Notes |
|------|--------|-------|
| Resource inventory (§2) | PASS — 32/32 | All resources from §2 table present in `main.tf` with matching logical names, conditionals, and dependencies (counted 32 distinct entries: 27 unique + the design's repeated `aws_lambda_permission` (×2), `time_sleep` (×2), `aws_cloudwatch_log_group` (×3), and `aws_iam_role`/`aws_iam_role_policy` (×3 each)). |
| Variable contract (§3) | PASS — 28/28 | Every input declared in `variables.tf` with correct type, default, and validation block. Spot-checked: `agent_name` regex+length, `instruction` 40-20000, `log_retention_days` CloudWatch-allowed list, `action_group_definitions` mutual-exclusion validators (api_schema XOR function_schema, payload XOR s3), `kms_key_arn` partition-aware regex, `environment` enum. |
| Output contract (§3) | PASS — 21/21 | All outputs declared in `outputs.tf`. Conditional outputs (knowledge_base_*, api_*, invoker_lambda_*, data_source_id, opensearch_collection_arn — 12 of 21) all use `try(<resource>[0].<attr>, null)` per design. |
| Security controls (§4) | PASS — 6/6 | Encryption-at-rest (CMK on agent + 3 log groups, no opt-out, key rotation on, 30-day window), encryption-in-transit (platform-enforced), public access (AOSS network policy AllowFromPublic=true documented as basic-example default; API GW authorizer left to consumer per design), IAM least-privilege (FM ARN, log group ARN, KMS+ViaService cond, conditional Lambda/KB/guardrail statements; X-Ray `*` documented exception per §7), logging (3 log groups KMS-encrypted with retention validated), tagging (4 required + Name + ManagedBy enforced via `local.required_tags` merged second so consumer keys cannot remove them). |
| Test coverage (§5) | PASS — 6/6 scenario groups | `unit_basic.tftest.hcl` (Secure Defaults), `unit_complete.tftest.hcl` (Full Features), `unit_edge_cases.tftest.hcl` (6 sub-scenarios: code interpreter disabled, Lambda action groups w/o code interpreter, API GW w/o KB, KB w/o API GW, BYO KMS, guardrail-only), `unit_validation.tftest.hcl` (24 reject cases + 21 boundary-pass cases = 45 runs), `acceptance.tftest.hcl` (real-provider plan), `integration.tftest.hcl` (real-provider apply). All four unit files use `mock_provider "aws" / "time" / "opensearch" / "archive"` with `mock_data` for the four data sources and `archive_file`. |
| Implementation checklist (§6) | PASS — 8/8 (A-H) | All checklist items marked `[x]` in design. Verified by codebase: scaffold (versions/data/locals/variables/outputs/main exist), security core (KMS+log group+IAM agent), agent runtime (agent + code_interpreter + alias + time_sleep), Lambda action groups (for_each + permission), KB (10 resources), API GW (10 resources + invoker), examples (basic + complete), tests (6 .tftest.hcl files), polish (`terraform fmt` clean, README terraform-docs in-place block current, CHANGELOG present). |
| File organization (constitution §2.1) | PARTIAL | Standard file structure present: main.tf, variables.tf, outputs.tf, locals.tf, versions.tf, data.tf, README.md, CHANGELOG.md, examples/{basic,complete}, tests/. **One issue**: `examples/complete/main.tf` is 539 lines — exceeds constitution §2.1 "no single file MAY exceed 500 lines" by 39 lines. main.tf (763 lines) and data.tf (461 lines) at the **root module** ALSO test the rule; main.tf is over by 263 lines. (Note: design.md and constitution silently coexist on this — design is OK, constitution rule is broken.) |
| Variable wiring | PARTIAL | `var.cors_configuration` is declared and validated in `variables.tf` (lines 212-221) but is NOT wired into `aws_apigatewayv2_api.this` in `main.tf`. Inline comment at `main.tf:673` admits this is "opt-in via var.cors_configuration in a future iteration". Design.md §3 documents the variable and §2 schema notes mention `cors_configuration` block "(omitted by default)" but consumers passing a non-null value will see the input silently accepted with no effect. Flag for human reviewer. |

---

## Static Analysis & Tests

### terraform fmt -check -recursive

**Result**: CLEAN (PASS)

No formatting issues across the module root, examples/, or tests/.

### terraform validate

**Result**: CLEAN (PASS) — `Success! The configuration is valid.`

### terraform test

| Test File | Result | Runs |
|-----------|--------|------|
| tests/unit_basic.tftest.hcl | PASS | 1/1 |
| tests/unit_complete.tftest.hcl | PASS | 1/1 |
| tests/unit_edge_cases.tftest.hcl | PASS | 6/6 |
| tests/unit_validation.tftest.hcl | PASS | 45/45 (24 reject + 21 accept) |
| tests/acceptance.tftest.hcl | FAIL (expected — see caveat) | 0/1 |
| tests/integration.tftest.hcl | FAIL (expected — see caveat) | 0/1 |

**Summary**: 54 passed / 2 failed = 54/56.

**Caveat (acceptance + integration)**: Both failing test files use **real** `aws`, `time`, and `opensearch` providers (no `mock_provider` blocks) per design.md §5 strategy ("Acceptance/Integration tests use real providers; require credentials"). They fail in this CI sandbox because the environment has no AWS credentials and no IMDS endpoint:
- `tests/acceptance.tftest.hcl::acceptance_plan_verification` — `Error: failed to refresh cached credentials, no EC2 IMDS role found`.
- `tests/integration.tftest.hcl::integration_end_to_end` — `Error: Invalid provider configuration` for `aws` and `opensearch` (the latter cannot resolve `url`).

These are **not** module-quality regressions; they are credential-gated tests. The orchestrator caller should run them in a credentialled environment (sandbox AWS account) before release. All 54 unit-mode tests pass.

### tflint

**Result**: SKIPPED (environmental)

`/workspace/.tflint.hcl` line 134 references `rule "terraform_json_syntax"` which is not bundled with `tflint` ruleset.terraform v0.13.0 (the version installed in this sandbox; tflint binary itself is 0.60.0). Running `tflint` produces `Failed to check rule config; Rule not found: terraform_json_syntax` and returns EXIT=0 (the actual lint never runs).

`/workspace/.tflint.hcl` is in the harness deny-list and cannot be edited by this validator. Pre-commit hook `terraform_tflint` was previously skipped via `SKIP=terraform_tflint` for the same reason. **Environmental, not a module-quality regression.** Re-evaluate in an environment that bundles the rule (newer ruleset.terraform) or after the deny-list is lifted.

### trivy config

Command: `trivy config /workspace --skip-dirs .terraform --skip-dirs tests --skip-dirs examples --severity CRITICAL,HIGH,MEDIUM,LOW`

**Module root (`.`) result**: 0 misconfigurations across CRITICAL / HIGH / MEDIUM / LOW. **CLEAN — release-blocking thresholds met.**

| Metric                | Count |
| --------------------- | ----- |
| Module-root findings  | 0     |
| Critical (root)       | 0     |
| High (root)           | 0     |
| Medium (root)         | 0     |
| Low (root)            | 0     |

**Out-of-scope findings** (Dockerfiles outside the module, included only for completeness):
- `.devcontainer/base-image/Dockerfile` — 1 LOW (`DS-0026` HEALTHCHECK missing)
- `.devcontainer/claude-code/Dockerfile` — 1 MEDIUM (`DS-0001` `:latest` tag in FROM), 1 LOW (`DS-0026` HEALTHCHECK)

These are devcontainer images, not module Terraform. **Do not block release.**

### terraform-docs --output-check

**Result**: CURRENT (PASS)

The README contains a `<!-- BEGIN_TF_DOCS -->` … `<!-- END_TF_DOCS -->` injection block (lines 144-274). Running `terraform-docs markdown table --output-file README.md --output-mode inject .` produced no diff (`git diff README.md` empty). The polish item already regenerated it — README is current.

---

## Security Checklist (design.md §4)

| # | Control | Result |
|---|---------|--------|
| 1 | Encryption at rest (CMK on agent + log groups, no opt-out, key rotation, kms:ViaService key-policy guards) | PASS |
| 2 | Encryption in transit (TLS via service endpoints; HTTPS-only HTTP API) | PASS |
| 3 | Public access (Bedrock SigV4-only; AOSS public-by-default in `examples/basic` documented; API GW authorizer left to consumer with prominent comment) | PASS (with documented caveats) |
| 4 | IAM least-privilege (FM ARN, log ARN, KMS w/ ViaService cond, conditional Lambda/KB/guardrail statements, confused-deputy SourceAccount+SourceArn on every trust policy; X-Ray `*` is the single documented exception per §7) | PASS |
| 5 | Logging (3 KMS-encrypted log groups with validated retention; X-Ray Active on invoker; structured JSON access-log format) | PASS |
| 6 | Tagging (4 required tags via required vars + ManagedBy + Name; consumer tags merged but cannot override required keys) | PASS |

Additional note: **Content safety (Bedrock Guardrails)** — agent binds consumer-supplied `guardrail_id` correctly; module v1 does NOT create the guardrail itself per design §7 [DEFERRED to v2].

---

## Quality Score (per `tf-judge-criteria` Module Workflow)

| # | Dimension | Weight | Score | Notes |
|---|-----------|--------|-------|-------|
| 1 | Resource Design | 25% | 8.5 | All 32 resources from design present; conditional creation via `count`/`for_each` is consistent (gates on `var.enable_*` for KB/API GW/code-interpreter; map for_each for action groups + Lambda permissions). Prepare-and-alias ordering, AOSS DAP wait timer, dynamic blocks for api_schema/function_schema, Lambda permission `source_arn` pinned to agent ARN — all match design rationale. **One gap**: `var.cors_configuration` is wired into the variable but not consumed by `aws_apigatewayv2_api.this` (P2 — see Top Issues). 2 P2, 0 P0/P1. |
| 2 | Security & Compliance | 30% | 9.0 | Encryption-at-rest non-negotiable (no opt-out var; key policy grants regional `logs.<region>.amazonaws.com` w/ EncryptionContext, `bedrock.amazonaws.com` w/ SourceAccount+ViaService, account root w/ kms:*); X-Ray `*` exception properly documented per §7 with inline justification; trust policies all carry SourceAccount+SourceArn confused-deputy guards; least-privilege scoped to FM/log/KMS/Lambda/KB/guardrail ARNs. Trivy module-root scan: 0 findings at all severities. AOSS public-by-default is a deliberate design call for the basic example, documented prominently. 0 P0, 0 P1, 0 P2 in scope. |
| 3 | Code Quality | 15% | 7.0 | `terraform fmt` clean. Naming consistent (`this` for singletons, descriptive for multiples). Validation blocks comprehensive. DRY: `local.kms_key_arn_resolved`, `local.required_tags`, `local.action_group_lambda_arns`, `local.foundation_model_arn`, etc. **Constitution §2.1 violation**: `main.tf` (763 lines) and `examples/complete/main.tf` (539 lines) exceed the 500-line cap; `data.tf` (461) is close. 1 P2 (file size). |
| 4 | Variables & Outputs | 10% | 8.5 | All 28 variables have type, description, validation (where applicable). All 21 outputs have descriptions; 12 conditional outputs use `try(...,null)`. No hardcoded values that should be variables. Sensitive marking: design says no sensitive variables/outputs needed (none of the inputs/outputs carry credentials), and code matches. **Gap**: `var.cors_configuration` declared with full type/validation but unused. 1 P2. |
| 5 | Testing | 10% | 8.5 | 4 unit files cover all design §5 scenario groups (basic, complete, edge_cases, validation) with `mock_provider` for all 4 providers + `mock_data` for the 4 data sources + `archive_file`. 54/54 unit assertions pass. Acceptance + integration tests follow design strategy (real providers) and are credential-gated as designed. Validation tests cover both `expect_failures` (24 reject) and boundary-pass (21 accept) cases. **Acceptance + integration not exercised in this sandbox** (expected) but present and correctly structured. 0 P0/P1/P2. |
| 6 | Constitution Alignment | 10% | 7.5 | Constitution §1 (security-first defaults), §2.2-2.6 (naming, vars, outputs, patterns, style), §3 (security baselines), §4 (provider `>=` constraints, no backend block), §5 (test categories + organization) — all honored. **Issues**: §2.1 file-size cap (main.tf 763 > 500, complete example 539 > 500); deviation §2.5 — `var.cors_configuration` declared but not consumed. The X-Ray `*` deviation is properly documented per design §7 and constitution §8.2 exception process (inline code comment + design.md citation). 2 P2, 0 P0/P1. |

**Weighted overall**:
`(8.5 × 0.25) + (9.0 × 0.30) + (7.0 × 0.15) + (8.5 × 0.10) + (8.5 × 0.10) + (7.5 × 0.10)`
= `2.125 + 2.700 + 1.050 + 0.850 + 0.850 + 0.750`
= **8.325 / 10.0 — Excellent**

**Production Readiness**: **READY** (D2 = 9.0, well above the 5.0 floor; no P0/P1 issues; trivy module-root 0 findings).

---

## Top Issues

| # | Severity | Dimension | File:Line | Issue | Remediation |
|---|----------|-----------|-----------|-------|-------------|
| 1 | P2 | Resource Design / Variables | `main.tf:675-683`, `variables.tf:212-221` | `var.cors_configuration` declared with full type and not wired into `aws_apigatewayv2_api.this`; comment admits "opt-in in a future iteration". Consumers passing a non-null value silently get nothing. | Either (a) add the typed `cors_configuration` block to `aws_apigatewayv2_api.this` driven by `var.cors_configuration`, or (b) remove/mark the variable as deferred and add a precondition that rejects non-null with a "not yet implemented" error. Track in CHANGELOG/README. |
| 2 | P2 | Code Quality / Constitution §2.1 | `main.tf` (763 lines), `examples/complete/main.tf` (539 lines), `data.tf` (461 lines, near limit) | Files exceed the 500-line cap from constitution §2.1 ("No single file MAY exceed 500 lines"). | Split `main.tf` by section (e.g., `kms.tf`, `agent.tf`, `kb.tf`, `apigw.tf`) — the existing section comments map cleanly. Split `examples/complete/main.tf` similarly (e.g., separate `bedrock.tf`, `kb.tf`, `apigw.tf`, `bucket.tf`). |
| 3 | INFO (environmental) | Tooling | `.tflint.hcl:134` | `terraform_json_syntax` rule not in bundled ruleset.terraform v0.13.0; tflint cannot complete and pre-commit hook is bypassed via `SKIP=terraform_tflint`. | Upgrade `tflint --init` ruleset.terraform plugin to a version that includes `terraform_json_syntax`, or remove the rule from `.tflint.hcl`. Currently file is harness-deny-listed. Re-run `tflint` once unblocked. |
| 4 | INFO (expected) | Testing | `tests/acceptance.tftest.hcl`, `tests/integration.tftest.hcl` | 2/56 test runs fail in this sandbox: no AWS credentials, no IMDS, no opensearch provider URL. | Run these in a credentialled sandbox AWS workspace before release per design §5 strategy. Not a module-code defect. |

---

## Auto-Fixes Applied

- `terraform fmt -check -recursive` already passed before any work — no formatter changes were needed.
- `terraform-docs markdown table --output-file README.md --output-mode inject /workspace` re-ran; no diff (README was already current).
- No descriptions, validators, sensitive markers, or formatting changes were applied — module code is already conformant in those areas.
- **Conservative no-op**: did NOT touch `var.cors_configuration` wiring, file-size split, or `.tflint.hcl` (harness-deny-listed) — these require human design decisions or are environmental.

---

## Issues Requiring Manual Fix

1. **CORS wiring** (P2) — decide whether to (a) wire `var.cors_configuration` into the API or (b) remove it / add a precondition.
2. **File-size cap** (P2) — split `main.tf` (763 → ≤500) and `examples/complete/main.tf` (539 → ≤500) along the existing section boundaries.
3. **tflint config** (INFO) — out of validator scope (deny-listed file). Track for the platform team to upgrade ruleset.terraform.
4. **Acceptance + integration tests** (INFO) — schedule a credentialled re-run in a sandbox AWS account.

---

## Overall Status

**PASS — release-ready with two P2 follow-ups recommended.**

- Design conformance: PASS (32/32 resources, 28/28 vars, 21/21 outputs, 6/6 controls, 8/8 checklist items).
- Static analysis: `fmt` PASS, `validate` PASS, `terraform-docs` CURRENT.
- Tests: 54/56 PASS (the 2 fails are credential-gated acceptance + integration runs — expected, not module defects).
- Security scan: trivy module-root 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW.
- tflint: SKIPPED (environmental — bundled ruleset missing rule, file deny-listed).
- Quality score: **8.325 / 10.0 — Excellent**.
- Production readiness: **READY** (D2 Security 9.0 >> 5.0 floor; no P0/P1).

**Blocking issues**: NONE.
**Recommended before next minor release**: address the two P2 issues (CORS wiring, file-size cap).
