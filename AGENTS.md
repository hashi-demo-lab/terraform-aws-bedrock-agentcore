# AGENT.md

# AI-Assisted Terraform Module Development (SDD)

AI-assisted development of enterprise-ready Terraform modules via spec-driven development. Tests before code. Security embedded in every phase.

## Core Principles

1. **Security-First**: All decisions prioritize security. No workarounds for security requirements. Constitution MUST rules are non-negotiable.
2. **Module-First**: Author well-structured modules using raw resources with secure defaults. Follow standard module structure (`examples/`, `tests/`, `modules/`).
3. **Single-Artifact Design**: All requirements, resources, interfaces, security controls, and test scenarios live in one `design.md`. One source of truth per feature.
4. **MCP-First**: Use MCP tools for AWS documentation and provider docs before general knowledge. Research resource behavior before writing code.
5. **TDD-First**: Tests before code. Write `.tftest.hcl` files from design scenarios, then implement the module to pass them. All tests green = implementation complete.
6. **Parallel Where Safe**: Independent tasks run concurrently. MCP-dependent tasks run sequentially.
7. **Quality Gates**: CRITICAL findings block progression. Reviews use evidence-based findings with citations.

## Workflow

See `tf-plan-module` SKILL.md (`.claude/skills/tf-plan-module/SKILL.md`) for the full 4-phase workflow: Understand, Design, Build+Test, Validate. See `tf-research-heuristics` skill for MCP tool priority and research strategies.

## Directory Layout

See constitution Section 3.2 (`.foundations/memory/constitution.md`) for the canonical file organization rules and directory map.

## Agent Architecture

Agents are subagents dispatched by orchestrator skills. Each agent has a single responsibility. Most agents read inputs from disk and write outputs to disk; research agents return findings in-memory to the orchestrator.

| Agent              | Model  | Purpose                                                             | Input                                                        | Output                                                      |
| ------------------ | ------ | ------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------- |
| `sdd-design`       | opus   | Produce design.md from clarified requirements and research findings | Requirements + research + constitution + template            | `specs/{FEATURE}/design.md`                                 |
| `sdd-research`     | opus   | Answer one specific research question using MCP tools               | Feature path + research question                             | Research findings (returned to orchestrator, not persisted) |
| `tf-test-writer`   | sonnet | Convert design.md test scenarios into `.tftest.hcl` files           | `specs/{FEATURE}/design.md` Section 5                        | `tests/*.tftest.hcl`                                        |
| `tf-task-executor` | opus   | Implement one checklist item from design.md                         | `specs/{FEATURE}/design.md` + checklist item + existing code | Modified `.tf` files                                        |

## Skill Architecture

Skills provide domain knowledge and orchestration logic. They are loaded into agent context as needed.

### Orchestrators

| Skill           | Purpose                                                                      |
| --------------- | ---------------------------------------------------------------------------- |
| `tf-plan-module` | 4-phase workflow entry point: Understand -> Design -> Build+Test -> Validate |
| `tf-implement`  | TDD-aware implementation: write tests first, run after each phase            |
| `tf-e2e-tester` | Automated E2E test harness: runs full workflow cycle with test defaults      |

### Domain Knowledge — User-Invocable

| Skill                        | Purpose                                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `tf-architecture-patterns`   | Patterns for module architecture -- resource composition, conditional creation, policy composition |
| `tf-implementation-patterns` | Patterns for Terraform code -- locals, for_each, dynamic blocks, lifecycle                         |
| `terraform-test`             | Terraform test patterns -- plan-only, conditional resources, validation errors, mocks              |
| `terraform-style-guide`      | Code style conventions -- naming, formatting, file organization                                    |

### Domain Knowledge — Background

| Skill                    | Purpose                                                                     |
| ------------------------ | --------------------------------------------------------------------------- |
| `tf-domain-taxonomy`     | 8-category taxonomy for scanning requirements and identifying gaps          |
| `tf-research-heuristics` | Strategies for MCP research -- what to look for, which tools, in what order |
| `tf-report-template`     | Validation results summary template                                         |
| `tf-security-baselines`  | CIS/NIST security baselines and risk rating framework                       |

## Prerequisites

See constitution Section 2 (`.foundations/memory/constitution.md`) for environment prerequisites (CLI tools, tokens, MCP servers).

## Testing Strategy

See constitution Section 6.3 (`.foundations/memory/constitution.md`) for TDD rules and test file conventions. See `tf-implement` skill for the test-first implementation workflow.

## Operational Notes

### GitHub Enterprise Authentication

For GHE repositories:

- **Authentication**: `gh auth login --hostname <hostname>` is required. Standard `gh auth login` only authenticates against github.com.
- **Operations**: Most `gh` commands (issue, pr, repo, etc.) do NOT accept `--hostname` flag. Use `GH_HOST` environment variable instead:
  ```bash
  export GH_HOST=github.enterprise.com
  gh issue create --title "Bug report"
  # Or inline:
  GH_HOST=github.enterprise.com gh pr create --title "Feature"
  ```

### Agent Output Persistence

Most agents have the Write tool and persist their own output artifacts to disk. The orchestrator verifies that expected output files exist after each agent dispatch. **Exception**: Research agents return findings in-memory — the orchestrator collects these and passes them to the design agent via `$ARGUMENTS`.

## Context Management

1. **NEVER call TaskOutput** to read subagent results — EXCEPT for research agents, whose findings are collected and forwarded to the design agent. All other agents write artifacts to disk.
2. **Verify file existence with Glob** after each agent completes -- do NOT read file contents into the orchestrator.
3. **Downstream agents read their own inputs from disk.** The orchestrator passes the FEATURE path plus scope via `$ARGUMENTS`. For the design agent, `$ARGUMENTS` also includes research findings collected from research agents.
4. **Research agents: parallel foreground Task calls** (NOT `run_in_background`). Launch ALL research agents in a single message with multiple Task tool calls, then collect their in-memory findings to pass to the design agent.
5. **Minimal $ARGUMENTS**: Only pass the FEATURE path + a specific question or scope. The one exception is research findings passed to the design agent.

**Remember**: Always verify with MCP tools. Security is non-negotiable.
