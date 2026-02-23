# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This repository is a **Terraform module development template** using **SDD** (Spec-Driven Development, 4-phase workflow). The goal is to author enterprise-ready, reusable Terraform modules — not to consume modules from a registry. Modules are written using raw resources with secure defaults, tested with `terraform test` in a TDD workflow, and published to a private registry.

## Primary Reference

See the root `./AGENTS.md` for the main project documentation, workflow phases, and agent/skill inventory.

@/workspace/AGENTS.md

## Constitution

Non-negotiable rules for all code generation live in the constitution. Read it before generating any Terraform code.

`.foundations/memory/constitution.md`

## Workflow Entry Points

| Command         | Purpose                                                           |
| --------------- | ----------------------------------------------------------------- |
| `/tf-plan-module` | Full 4-phase workflow: Clarify, Design, Implement (TDD), Validate |
| `/tf-implement` | Implementation only — starts from an existing `design.md`         |

## Design Template

When creating design documents, use the canonical template at `.foundations/templates/design-template.md`.

## Key Conventions

- Workflow conventions are defined in the orchestrator skills (`tf-plan-module`, `tf-implement`). Follow AGENTS.md `## Context Management` for subagent rules.
- Key scripts: `validate-env.sh` (environment checks), `post-issue-progress.sh` (GitHub updates), `checkpoint-commit.sh` (git automation) — all in `.foundations/scripts/bash/`.

## Updating AGENTS.md Files

When you discover new information that would be helpful for future development work:

- **Update existing AGENTS.md files** when you learn implementation details, debugging insights, or architectural patterns specific to that component
- **Create new AGENTS.md files** in relevant directories when working with areas that don't yet have documentation
- **Add valuable insights** such as common pitfalls, debugging techniques, dependency relationships, or implementation patterns
