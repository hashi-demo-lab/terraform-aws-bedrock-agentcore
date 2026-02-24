---
name: tf-provider-implement
description: SDD Phases 3-4 for provider development. TDD implementation and validation from an existing provider-design-{resource}.md.
user-invocable: true
argument-hint: "[feature-name] [resource-name] - Implement from existing specs/{feature}/provider-design-{resource}.md"
---

# SDD — Provider Implement

Builds and validates a Terraform provider resource from `specs/{FEATURE}/provider-design-{resource}.md` using TDD.

Post progress at key steps: `bash .foundations/scripts/bash/post-issue-progress.sh $ISSUE_NUMBER "<step>" "<status>" "<summary>"`. Valid status values: `started`, `in-progress`, `complete`, `failed`.
Checkpoint after each phase: `bash .foundations/scripts/bash/checkpoint-commit.sh --dir . --prefix feat "<step_name>"`. The `<step_name>` must be a short hyphenated identifier (e.g., `"scaffolding"`, `"checklist-item-1"`, `"validation"`) — NOT a sentence or file path.

## Prerequisites

1. Resolve `$FEATURE` and `$RESOURCE` from `$ARGUMENTS` or current git branch name.
2. Verify `specs/{FEATURE}/provider-design-{resource}.md` exists via Glob (try `specs/$FEATURE/provider-design-*.md` if exact name unknown). Stop if missing — tell user to run `/tf-provider-plan` first. Capture `$DESIGN_FILE` path for passing to subagents.
3. Find `$ISSUE_NUMBER` from `$ARGUMENTS` or `gh issue list --search "$FEATURE"`.

## Phase 3: Build + Test

4. Launch `tf-provider-developer` agent with `$DESIGN_FILE` for the first checklist item (typically "A: Schema & test stubs"). Verify `_test.go` files exist via Glob.
5. Run `go build -o /dev/null .` as the red TDD baseline — schema and stubs exist but CRUD is not implemented. Checkpoint commit.
6. Extract remaining checklist items from the design file §6 via Grep (look for `- [ ]` lines).
7. For each remaining checklist item (sequentially — items depend on prior items):
   - Launch `tf-provider-developer` agent with `$DESIGN_FILE` and the specific checklist item description.
   - Run `go build -o /dev/null .` and `go test -c -o /dev/null ./internal/service/<service>` to verify compilation.
   - Checkpoint commit.
8. After all items: run `go build -o /dev/null .` + `go vet ./...`. If compilation errors remain, re-launch `tf-provider-developer` agent targeted at the specific errors (max 2 fix rounds).
9. Verify all checklist items in the design file §6 are marked `[x]` via Grep. If any remain `[ ]`, either mark them (if the work was done by a prior item) or flag the gap before proceeding.

## Phase 4: Validate

10. Launch `tf-provider-validator` agent with `$DESIGN_FILE` and service directory. Review output; if auto-fixes were applied, run `go build -o /dev/null .` to confirm fixes compile.
11. If remaining issues reported by validator, launch `tf-provider-developer` agent targeted at the specific issues (max 2 fix rounds). Run `go build` and `go vet` after each fix round.
12. Ask user via `AskUserQuestion` whether to run acceptance tests (`TF_ACC=1`, real API credentials). If confirmed, launch `tf-provider-validator` with `run_acceptance_tests=true` and test pattern from user. Report pass/fail per test function.
13. Write validation report to `specs/{FEATURE}/reports/` by reading the `tf-report-template` skill inline and applying the provider template format (`tf-report-template/template/tf-provider-template.md`). This is not a subagent dispatch — write the report directly.
14. Checkpoint commit, push branch, create PR linking to `$ISSUE_NUMBER`.

## Done

Report: build pass/fail, test compilation, acceptance test results (if run), validation status, PR link.
