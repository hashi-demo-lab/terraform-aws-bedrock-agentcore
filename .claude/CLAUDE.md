# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This repository is a **Terraform module development template** using **SDD** (Spec-Driven Development, 4-phase workflow). The goal is to author enterprise-ready, reusable Terraform modules — not to consume modules from a registry. Modules are written using raw resources with secure defaults, tested with `terraform test` in a TDD workflow, and published to a private registry.

## Primary Reference

See the root `./AGENTS.md` for the main project documentation, workflow phases, and agent/skill inventory.

@/workspace/AGENTS.md

## Workflow Entry Points

| Command         | Purpose                                                           |
| --------------- | ----------------------------------------------------------------- |
| `/tf-plan-module` | Full 4-phase workflow: Clarify, Design, Implement (TDD), Validate |
| `/tf-implement-module` | Implementation only — starts from an existing `design.md`         |
| `/tf-provider-plan` | Full 4-phase workflow for provider resources: Clarify, Design, Implement, Validate |
| `/tf-provider-implement` | Implementation only — starts from an existing provider `design.md` |

## Constitutions

Non-negotiable rules for all code generation live in the constitutions. Read the relevant one before generating code.

- **Module constitution**: `.foundations/memory/module-constitution.md`
- **Provider constitution**: `.foundations/memory/provider-constitution.md`

## Design Templates

When creating design documents, use the canonical template for the relevant workflow:

- **Module design**: `.foundations/templates/design-template.md`
- **Provider design**: `.foundations/templates/provider-design-template.md`

## Key Conventions

- Workflow conventions are defined in the orchestrator skills (`tf-plan-module`, `tf-implement-module`, `tf-provider-plan`, `tf-provider-implement`). Follow AGENTS.md `## Context Management` for subagent rules.
- Key scripts: `validate-env.sh` (environment checks), `post-issue-progress.sh` (GitHub updates), `checkpoint-commit.sh` (git automation) — all in `.foundations/scripts/bash/`.

## Updating AGENTS.md Files

When you discover new information that would be helpful for future development work:

- **Update existing AGENTS.md files** when you learn implementation details, debugging insights, or architectural patterns specific to that component
- **Create new AGENTS.md files** in relevant directories when working with areas that don't yet have documentation
- **Add valuable insights** such as common pitfalls, debugging techniques, dependency relationships, or implementation patterns
