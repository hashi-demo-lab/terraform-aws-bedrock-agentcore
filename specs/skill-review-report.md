# SDD Skill Review Report

Cross-file consistency review of the `/tf-module-plan` and `/tf-module-implement` orchestrator skills,
their 4 subagents, and ~10 supporting skills.

**Date**: 2026-02-23
**Scope**: Orchestrator skills, subagent instructions, constitution, report template, validation scripts

---

## Executive Summary

| Severity | Count |
| -------- | ----- |
| High     | 1     |
| Medium   | 6     |
| Low      | 0     |
| Refuted  | 2     |

7 confirmed findings. 2 candidates (F6, F7) were investigated and refuted.

---

## Findings Overview

| ID | Severity | Status   | Summary                                                        |
| -- | -------- | -------- | -------------------------------------------------------------- |
| F1 | High     | Confirmed | AGENTS.md references stale agent name `sdd-research`          |
| F2 | Medium   | Confirmed | Constitution lists 3 test files; workflow produces 4           |
| F3 | Medium   | Confirmed | Report template missing `edge_cases.tftest.hcl`               |
| F4 | Medium   | Deferred | Report template requires tflint/pre-commit results not collected by agent |
| F5 | Medium   | Confirmed | validate-env.sh Terraform version check (`>= 1.5`) vs constitution (`>= 1.7`) |
| F6 | —        | Refuted  | Test-writer error-fixing is module developer's responsibility  |
| F7 | —        | Refuted  | checkpoint-commit.sh prefix difference is intentional          |
| F8 | Medium   | Confirmed | Test-writer step 1 omits Section 2 extraction                 |
| F9 | Medium   | Deferred | WARN-level tools treated as required in Phase 4                |

---

## Detailed Findings

### F1 — AGENTS.md references stale agent name `sdd-research` [HIGH]

**Evidence**:
- `AGENTS.md:7` — `EXCEPT for research agents (`sdd-research`), whose findings are collected`
- `AGENTS.md:30` — `Research agents (`sdd-research`) return findings in-memory`
- Actual agent file: `.claude/agents/tf-module-research.md` (name: `tf-module-research`)
- `tf-module-plan/SKILL.md:23` uses the correct name: `Launch 3-4 concurrent `tf-module-research` subagents`

**Impact**: The context management rules in AGENTS.md — which the orchestrator loads every run — reference an agent name that does not exist. An LLM orchestrator following these rules literally could fail to match the exception for research agents, potentially trying to read disk artifacts instead of collecting in-memory findings.

**Suggested Fix**: Replace both occurrences of `sdd-research` in `AGENTS.md` with `tf-module-research`.

---

### F2 — Constitution lists 3 test files; workflow produces 4 [MEDIUM]

**Evidence**:
- `constitution.md:242-246` (§5.3 Test Organization) lists 3 files:
  ```
  basic.tftest.hcl
  complete.tftest.hcl
  validation.tftest.hcl
  ```
- `tf-module-test-writer.md:214` — `four test files`
- `tf-module-test-writer.md:222-228` (Output section) lists 4 files including `tests/edge_cases.tftest.hcl`
- `design-template.md:105` — defines 5 scenario groups mapping to 4 files (Feature Interactions and edge cases map to `edge_cases.tftest.hcl`)

**Impact**: The constitution is the authoritative reference for module structure. Its omission of `edge_cases.tftest.hcl` means the documented file tree is incomplete. Agents or humans consulting only the constitution will have an inaccurate picture of expected test artifacts.

**Suggested Fix**: Add `edge_cases.tftest.hcl` to the constitution's §5.3 test file listing and add a brief description of its purpose.

---

### F3 — Report template missing `edge_cases.tftest.hcl` [MEDIUM]

**Evidence**:
- `tf-report-template/template/tf-module-template.md:11-15` — terraform test table lists only:
  ```
  basic.tftest.hcl
  complete.tftest.hcl
  validation.tftest.hcl
  ```
- The test-writer agent produces 4 files (`tf-module-test-writer.md:222-228`), including `edge_cases.tftest.hcl`

**Impact**: Edge case test results are never formally recorded in the validation report. The quality gate report will be missing a row, even when the tests exist and were executed.

**Suggested Fix**: Add an `edge_cases.tftest.hcl` row to the terraform test table in `tf-module-template.md`.

---

### F4 — Report template requires tflint/pre-commit results not collected by agent [MEDIUM]

**Evidence**:
- `tf-module-implement/SKILL.md:38` (step 12) lists 5 parallel commands:
  ```
  terraform test, terraform validate, terraform fmt -check -recursive, trivy config ., terraform-docs markdown . > README.md
  ```
  No `tflint` or `pre-commit run --all-files` present.
- `tf-report-template/SKILL.md:36-44` PASS criteria requires both:
  - `tflint reports no findings`
  - `pre-commit run --all-files passes`
- `tf-report-template/template/tf-module-template.md:31-41` has dedicated sections for both tflint and pre-commit results

**Note**: `tflint` and `pre-commit` are part of project scaffolding (pre-commit hooks), not commands the agent invokes directly. They run automatically on commit via the pre-commit framework.

**Impact**: The report template and PASS criteria reference tflint and pre-commit results, but these are produced by scaffolding hooks, not agent commands. The agent has no mechanism to capture their output for the report.

**Suggested Fix**: Update the report template and PASS criteria to clarify that tflint and pre-commit results come from scaffolding hooks. Either (a) have step 12 capture the hook output from the checkpoint commit for the report, or (b) mark those report sections as "validated by pre-commit hooks" rather than requiring explicit command output.

---

### F5 — validate-env.sh Terraform version check (`>= 1.5`) vs constitution (`>= 1.7`) [MEDIUM]

**Evidence**:
- `validate-env.sh:134` — `[[ "$TF_MINOR" -ge 5 ]]` (passes Terraform >= 1.5)
- `validate-env.sh:137` — error message: `requires >= 1.5`
- `constitution.md:181` (§4.1) — `required_version = ">= 1.7"`

**Impact**: Users with Terraform 1.5 or 1.6 will pass the environment validation gate but then fail at `terraform validate` when modules declare `required_version = ">= 1.7"` in `versions.tf`. The failure surfaces later in the workflow with a less clear error message.

**Suggested Fix**: Update `validate-env.sh` to check `TF_MINOR -ge 7` and update the error message to reference `>= 1.7`.

---

### F6 — Test-writer agent has no error-fixing mode [REFUTED]

**Evidence**:
- `tf-module-implement/SKILL.md:33` (step 10): `re-launch `tf-module-test-writer` agent with the error output and any data sources reported by task executors as context`
- `tf-module-test-writer.md` instructions (steps 1-7): The agent only reads `design.md` Section 5 and generates tests from scratch. There is no instruction to parse error output, diagnose failures, or modify existing test files.

**Conclusion**: The test-writer's role is initial test generation only. When tests fail after all checklist items are implemented, the **module developer agent** iterates on the code to make tests pass — the tests are the spec, not the thing being fixed. Step 10's re-launch of the test-writer is a fallback for cases where test scaffolding itself is invalid (e.g., missing mock data for newly introduced data sources), not a general error-fixing loop. No change needed to the test-writer agent.

---

### F7 — checkpoint-commit.sh prefix difference [REFUTED]

**Investigation**:
- `tf-module-plan/SKILL.md:13` — `bash .foundations/scripts/bash/checkpoint-commit.sh "<step_name>"` (no `--prefix` flag; uses default)
- `tf-module-implement/SKILL.md:13` — `bash .foundations/scripts/bash/checkpoint-commit.sh --dir . --prefix feat "<step_name>"`

**Conclusion**: The difference is intentional and semantically correct. The plan phase produces design documentation artifacts (default `docs` prefix is appropriate). The implement phase produces feature code (`feat` prefix is appropriate). No action needed.

---

### F8 — Test-writer step 1 omits Section 2 extraction [MEDIUM]

**Evidence**:
- `tf-module-test-writer.md:3` (description): `Reads Sections 2, 3, and 5 of the design document`
- `tf-module-test-writer.md:22` (step 1): `Extract Section 3 (Interface Contract) for variables and provider requirements, and Section 5 (Test Scenarios) for test generation`
  - Section 2 is not mentioned in step 1
- Step 2 (`tf-module-test-writer.md:24`) references Section 2 for `versions.tf`: `from the design's architectural decisions (Section 2)`
- Constraints (`tf-module-test-writer.md:204`) reference Section 2: `Check the Schema Notes column in design.md Section 2`
- Constraints (`tf-module-test-writer.md:206`) reference Section 2: `Check `design.md` Section 2 for data sources in the resource inventory`

**Impact**: The step-by-step instructions in step 1 do not tell the agent to extract Section 2 upfront, even though later steps and constraints depend on it. An agent following the instructions literally may not load Section 2 data until it encounters a reference in step 2 or constraints, potentially causing backtracking or missed information (Schema Notes, data sources for mock_data blocks).

**Suggested Fix**: Update step 1 to explicitly include Section 2: `Extract Section 2 (Resource Inventory) for provider versions, data sources, and Schema Notes; Section 3 (Interface Contract) for variables; and Section 5 (Test Scenarios) for test generation.`

---

### F9 — WARN-level tools treated as required in Phase 4 [MEDIUM]

**Evidence**:
- `validate-env.sh:141` — tflint classified as `WARN` (non-blocking)
- Similar WARN classification for pre-commit, trivy, and terraform-docs in validate-env.sh
- `tf-module-implement/SKILL.md:38` (step 12) directly invokes `trivy config .` and `terraform-docs markdown . > README.md`
- `tf-report-template/SKILL.md:36-44` PASS criteria requires tflint, pre-commit, and trivy results

**Impact**: Phase 4 can be reached without WARN-level tools installed (validate-env.sh does not block on their absence). But the orchestrator then attempts to execute them in step 12 and the report requires their output for PASS criteria. This creates a late-stage failure that should have been caught at the gate.

**Suggested Fix**: Either (a) promote tflint, pre-commit, trivy, and terraform-docs to GATE level in validate-env.sh, or (b) add graceful handling in step 12 and the report template for when these tools are absent (e.g., "SKIPPED — tool not installed").

---

## Summary of Suggested Actions

| Priority | Action                                                                 |
| -------- | ---------------------------------------------------------------------- |
| F1 | **Fixed** | Stale agent name in AGENTS.md → `tf-module-research`           |
| F2 | **Fixed** | Added `edge_cases.tftest.hcl` to constitution §5.3             |
| F3 | **Fixed** | Added `edge_cases.tftest.hcl` to report template               |
| F4 | Deferred | Report template tflint/pre-commit sections — scaffolding concern |
| F5 | **Fixed** | validate-env.sh and constitution aligned to `>= 1.14`          |
| F8 | **Fixed** | Test-writer step 1 now includes Section 2                      |
| F9 | Deferred | WARN/GATE classification — no change needed now                |
