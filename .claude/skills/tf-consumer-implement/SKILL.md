---
name: tf-consumer-implement
description: SDD Phases 3-4 for consumer provisioning. Implementation and validation from an existing consumer-design.md. Composes modules, validates, deploys to sandbox, creates PR.
user-invocable: true
argument-hint: "[feature-name] - Implement from existing specs/{feature}/consumer-design.md"
---

# SDD — Consumer Implement

Builds and validates a consumer deployment from `specs/{FEATURE}/consumer-design.md`.

Post progress at key steps: `bash .foundations/scripts/bash/post-issue-progress.sh $ISSUE_NUMBER "<step>" "<status>" "<summary>"`. Valid status values: `started`, `in-progress`, `complete`, `failed`.
Checkpoint after each phase: `bash .foundations/scripts/bash/checkpoint-commit.sh --dir . --prefix feat "<step_name>"`. The `<step_name>` must be a short hyphenated identifier (e.g., `"scaffolding"`, `"checklist-item-b"`, `"validation"`) — NOT a sentence or file path.

## Prerequisites

1. Resolve `$FEATURE` from `$ARGUMENTS` or current git branch name.
2. Run `bash .foundations/scripts/bash/validate-env.sh --json`. Stop if `gate_passed=false`.
3. Verify `specs/{FEATURE}/consumer-design.md` exists via Glob. Stop if missing — tell user to run `/tf-consumer-plan` first.
4. Find `$ISSUE_NUMBER` from `$ARGUMENTS` or `gh issue list --search "$FEATURE"`.

## Phase 3: Build

5. Extract checklist items from consumer-design.md Section 5 via Grep.
6. For each checklist item (sequentially — items depend on prior items):
   - Launch `tf-consumer-developer` agent with FEATURE path and item description.
   - When it completes, verify expected files exist via Glob.
   - Run `terraform fmt -check` and `terraform validate` (validate may require `terraform init` first).
   - Checkpoint commit.
   Use concurrent subagents for independent items only when their outputs do not overlap.
7. After all items: run `terraform validate`. If failures remain, re-launch `tf-consumer-developer` agent targeted at the specific errors (max 2 fix rounds).
8. Verify all checklist items in consumer-design.md Section 5 are marked `[x]` via Grep. If any remain `[ ]`, either mark them (if the work was done by a prior item) or flag the gap before proceeding.

## Phase 4: Validate

9. Launch `tf-consumer-validator` agent with FEATURE path. The validator performs:
   - Design conformance check (modules, wiring, variables vs design)
   - Static analysis (`terraform fmt`, `terraform validate`, `tflint`, `trivy`)
   - Quality scoring using `tf-judge-criteria`
   Security is enforced by Sentinel policies at the workspace level and by modules being inherently secure — the validator does not perform a separate security review.
   Include `sandbox_deploy=false` in `$ARGUMENTS` for the initial validation pass (deploy is a separate step).
10. Review validator output. If quality score < 7.0:
    - Launch `tf-consumer-developer` agent targeted at specific issues (max 2 fix rounds).
    - Re-run `tf-consumer-validator` after fixes.
11. Ask user via `AskUserQuestion` whether to deploy to sandbox. Options:
    - **Deploy to sandbox** — will trigger plan+apply in HCP Terraform sandbox workspace
    - **Skip sandbox** — proceed to report without deploying
    If confirmed, re-launch `tf-consumer-validator` with `sandbox_deploy=true` and workspace details. Capture run URL and deploy status.
12. Write deployment report to `specs/{FEATURE}/reports/` by reading the `tf-report-template` skill inline and applying the consumer template format (`tf-report-template/template/tf-consumer-template.md`). This is not a subagent dispatch — write the report directly. Include: static analysis results, quality score, sandbox deployment results (if run).
13. Checkpoint commit, push branch, create PR linking to `$ISSUE_NUMBER`.
14. Ask user via `AskUserQuestion`: "Destroy sandbox resources?" Options:
    - **Yes, destroy** — trigger destroy run in sandbox workspace
    - **No, keep** — leave sandbox resources running
    If destroy confirmed, run the destroy and report status.

## Done

Report: validation status, quality score, sandbox deploy status (if run), PR link.
