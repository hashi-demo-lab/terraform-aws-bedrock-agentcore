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
4. Identify the service directory from the design file (§2 or §3 will reference `internal/service/<service>/`).

## Phase 3: Build + Test

5. Launch `tf-provider-developer` agent with `$DESIGN_FILE` for the first checklist item (typically "A: Schema & test stubs"). This creates the resource file with schema, model struct, empty CRUD methods, and test stubs. Verify `_test.go` files exist via Glob.
6. Run `go build -o /dev/null .` as the red TDD baseline — schema and stubs exist but CRUD is not implemented, so tests will not pass. This verifies the code compiles. Checkpoint commit.
7. Extract remaining checklist items from the design file §6 via Grep (look for `- [ ]` lines).
8. For each remaining checklist item (sequentially — items depend on prior items):
   - Launch `tf-provider-developer` agent with `$DESIGN_FILE` and the specific checklist item description.
   - When it completes, run `go build -o /dev/null .` to verify compilation.
   - Run `go test -c -o /dev/null ./internal/service/<service>` to verify test compilation.
   - Checkpoint commit.
9. After all items: run `go build -o /dev/null .` + `go vet ./...`. If compilation errors remain, re-launch `tf-provider-developer` agent targeted at the specific errors (max 2 fix rounds).
10. Verify all checklist items in the design file §6 are marked `[x]` via Grep. If any remain `[ ]`, either mark them (if the work was done by a prior item) or flag the gap before proceeding.

## Phase 4: Validate

11. Launch `tf-provider-validator` agent with `$FEATURE` path and service directory. The validator performs:
    - Design conformance check (schema, CRUD, error handling, tests vs design)
    - Build & static analysis (`go build`, `go vet`, `gofmt`, `staticcheck`)
    - Test compilation and coverage verification
    - Code review against constitution
    - Auto-fixes for unambiguous issues
12. Review validator output. If auto-fixes were applied, run `go build -o /dev/null .` and `go test -c -o /dev/null ./internal/service/<service>` again to confirm fixes compile.
13. If remaining issues reported by validator, launch `tf-provider-developer` agent targeted at the specific issues (max 2 fix rounds). After each fix round, run `go build` and `go vet` to verify.
14. Ask user via `AskUserQuestion` whether to run acceptance tests. Acceptance tests require `TF_ACC=1` and real API credentials — they create real infrastructure. Options:
    - **Run acceptance tests** — will execute `TF_ACC=1 go test ./internal/service/<service> -run TestAcc -v -timeout 60m`
    - **Skip acceptance tests** — proceed to report without running tests
    - **Run specific tests only** — specify test function pattern
    If confirmed, run the tests and report pass/fail per test function.
15. Write validation report to `specs/{FEATURE}/reports/` by reading the `tf-report-template` skill inline and applying the provider template format (`tf-report-template/template/tf-provider-template.md`). This is not a subagent dispatch — write the report directly. Include: build results, static analysis, test compilation, code review findings, acceptance test results (if run), and any remaining issues.
16. Checkpoint commit, push branch, create PR linking to `$ISSUE_NUMBER`.

## Done

Report: build pass/fail, test compilation, acceptance test results (if run), validation status, PR link.
