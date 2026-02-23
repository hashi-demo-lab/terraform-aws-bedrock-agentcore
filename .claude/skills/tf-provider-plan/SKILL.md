---
name: tf-provider-plan
description: SDD Phases 1-2 for provider development. Clarify requirements, research, produce provider-design-{resource}.md, and await human approval before any code is written.
user-invocable: true
argument-hint: "[resource-name] [provider-name] - Brief description of what the provider resource should manage"
---

# SDD — Provider Plan

Produces `specs/{FEATURE}/provider-design-{resource}.md` from requirements. Stops for human approval before any code is written.

Post progress at key steps: `bash .foundations/scripts/bash/post-issue-progress.sh $ISSUE_NUMBER "<step>" "<status>" "<summary>"`. Valid status values: `started`, `in-progress`, `complete`, `failed`.
Checkpoint after each phase: `bash .foundations/scripts/bash/checkpoint-commit.sh "<step_name>"`. The `<step_name>` must be a short hyphenated identifier (e.g., `"clarify"`, `"research-and-design"`, `"design-approved"`) — NOT a sentence or file path.

## Phase 1: Understand

1. Run `bash .foundations/scripts/bash/validate-env.sh --json`. Stop if `gate_passed=false`. Then separately verify Go is available: `go version` (Go >= 1.21 required). Stop if Go is not installed or version is insufficient.
2. Parse `$ARGUMENTS` for resource name (pattern: `{provider}_{service}_{resource}`), provider name, and description. Derive `$RESOURCE` short name (e.g., `bucket` from `mycloud_storage_bucket`). Ask via `AskUserQuestion` if incomplete.
3. Create GitHub issue: read `.foundations/templates/issue-body-template.md`, fill in the placeholders with parsed requirements, and run `gh issue create --title "Provider Resource: {provider}_{service}_{resource}" --body "$FILLED_BODY"`. Capture `$ISSUE_NUMBER`. Update the issue body again after Step 6 (clarification) to include API decisions and scope boundaries.
4. Create feature branch: `bash .foundations/scripts/bash/create-new-feature.sh --json --issue $ISSUE_NUMBER --short-name "<resource-name>" "<feature description>"`. Parse the JSON output to capture `$BRANCH_NAME` as `$FEATURE`.
5. Scan requirements against the `tf-domain-category` skill — focus on API behavior ambiguity, state management decisions (ForceNew vs in-place update), and error handling patterns.
6. Ask up to 4 clarification questions via `AskUserQuestion`. Must include:
   - **Update behavior**: Which attributes support in-place update vs require replacement (ForceNew)?
   - **Test environment**: What API credentials/environment variables are needed for acceptance tests?
   - A security-related question (sensitive attributes, credential handling)
   - Scope/feature clarification as needed
7. Launch 3-4 concurrent `tf-provider-research` subagents (run in foreground — they use MCP tools):
   - **API/SDK documentation**: Endpoints, request/response schemas, error types, rate limits, async behavior
   - **Plugin Framework patterns**: Schema design conventions, plan modifiers, validators, state management patterns for similar resources
   - **Existing provider implementations**: How other providers handle the same or similar cloud service — CRUD patterns, error handling, test structure
   - **Import and state patterns**: Import ID format, composite keys, state migration (if applicable)
   Wait for all to complete. Collect findings for the design agent.

## Phase 2: Design

8. Launch `tf-provider-design` agent with FEATURE path, RESOURCE name, clarified requirements, and research findings summary. The agent reads the constitution and design template itself. Output: `specs/{FEATURE}/provider-design-{resource}.md`.
9. Verify `specs/{FEATURE}/provider-design-{resource}.md` exists via Glob. Re-launch once if missing.
10. Grep to confirm all 7 sections present (`## 1. Purpose` through `## 7. Open Questions`). Fix inline if any missing.
11. Present design summary to user via `AskUserQuestion`:
    - Attribute count (required, optional, computed)
    - CRUD operations covered (Create, Read, Update, Delete, Import)
    - Test scenario count per group (basic, disappears, full features, update, validation, error handling)
    - Implementation checklist item count
    - Options: approve, review file first, request changes
12. If changes requested, apply and re-present. Repeat until approved.

## Done

Design approved at `specs/{FEATURE}/provider-design-{resource}.md`. Run `/tf-provider-implement $FEATURE $RESOURCE` to build.
