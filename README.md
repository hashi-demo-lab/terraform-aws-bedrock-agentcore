# AI-Assisted Terraform Module Development (SDD)

A template repository for AI-assisted Terraform module development using spec-driven development (SDD). The workflow compresses module authoring into four phases -- Understand, Design, Build+Test, and Validate -- driven by a single design document. One `design.md` replaces separate spec, plan, contract, data model, and task files, tests are written before module code, and security controls are embedded in every phase rather than bolted on as a separate review.

## Workflow Overview

```
 Phase 1              Phase 2           Phase 3              Phase 4
 ────────────        ────────────      ────────────         ────────────
 UNDERSTAND      →   DESIGN       →   BUILD + TEST    →   VALIDATE
 Clarify + Research   Single doc        TDD-style           Security + Quality

 ~8 min               ~8 min            ~15 min              ~5 min
 0 artifacts          1 artifact        Module code          Test results
                      (design.md)       + test files         Security scan
```

**Phase 1: Understand** -- Validate the environment, intake requirements from the user prompt or GitHub issue, and clarify ambiguities against an 8-category taxonomy. A security-defaults question is always asked to prevent the most expensive class of downstream error. Parallel MCP research agents fetch provider docs and AWS best practices.

**Phase 2: Design** -- A single agent produces `specs/{FEATURE}/design.md` containing the interface contract (inputs/outputs), resource inventory, security controls with CIS/Well-Architected references, test scenarios, and an implementation checklist. This one document is the sole source of truth for the module.

**Phase 3: Build + Test** -- Tests are written first. Each test scenario from the design document becomes a `run` block in a `.tftest.hcl` file with concrete assertions. Module code is then implemented phase-by-phase, with `terraform validate` and `terraform test` run after each phase to track progress.

**Phase 4: Validate** -- All checks run in parallel: `terraform test`, `terraform validate`, `terraform fmt -check`, `trivy config .`, and `terraform-docs`. Critical or high security findings block completion. When all checks pass, the module is ready.

## Quick Start

```bash
# Prerequisites
gh auth status        # GitHub CLI authenticated
echo $TFE_TOKEN       # HCP Terraform token set

# Run the full workflow (Understand -> Design -> Build+Test -> Validate)
/tf-plan-module my-module aws - Creates an S3 bucket with encryption and versioning

# Or implement from an existing design document
/tf-implement-module my-module
```

## Prerequisites

| Requirement | Check | Notes |
|-------------|-------|-------|
| GitHub CLI | `gh auth status` | Authenticated to your GitHub host |
| HCP Terraform token | `echo $TFE_TOKEN` | Required for publishing and remote test runs |
| Terraform | `terraform version` | >= 1.5 |
| MCP servers | Configured in Claude Code | `terraform` and `aws-knowledge-mcp-server` |
| trivy | `trivy --version` | Optional -- used in Phase 4 security scanning |
| terraform-docs | `terraform-docs --version` | Optional -- generates module documentation |
| pre-commit | `pre-commit --version` | Optional -- runs fmt, validate, tflint, trivy, terraform-docs |

## Project Structure

```
.
├── .claude/
│   ├── CLAUDE.md                         # Project context for Claude Code
│   ├── agents/                           # Agent definitions (4 agents)
│   │   ├── sdd-design.md                 # Produces design.md from requirements + research
│   │   ├── sdd-research.md               # Answers research questions via MCP tools
│   │   ├── tf-test-writer.md             # Converts design scenarios to .tftest.hcl
│   │   └── tf-task-executor.md           # Implements one checklist item from design.md
│   └── skills/                           # Skill definitions (8 skills + 3 orchestrators)
│       ├── tf-plan-module/              # Orchestrator: full 4-phase workflow
│       ├── tf-implement-module/           # Orchestrator: TDD-aware implementation
│       ├── tf-e2e-test-module/           # Orchestrator: automated E2E test harness
│       ├── tf-domain-taxonomy/           # 8-category requirement scanning
│       ├── tf-research-heuristics/       # MCP research strategies
│       ├── tf-architecture-patterns/     # Module architecture patterns
│       ├── tf-implementation-patterns/   # Terraform code patterns
│       ├── terraform-test/               # Terraform test patterns (.tftest.hcl)
│       ├── terraform-style-guide/        # Code style conventions
│       ├── tf-report-template/           # Validation results summary
│       └── tf-security-baselines/        # CIS/NIST security baselines
├── .foundations/
│   ├── memory/
│   │   └── constitution.md               # Non-negotiable rules for all agents
│   ├── templates/
│   │   └── design-template.md            # Standardized template for design.md
│   └── scripts/bash/
│       ├── validate-env.sh               # Environment validation (Phase 1)
│       ├── checkpoint-commit.sh          # Progress checkpoint commits
│       ├── common.sh                     # Shared shell utilities
│       ├── create-new-feature.sh         # Feature directory scaffolding
│       └── post-issue-progress.sh        # GitHub issue progress updates
├── .github/
│   └── ISSUE_TEMPLATE/
│       └── module-request.yml            # Module request issue template
├── AGENTS.md                             # Full project documentation
├── specs/{FEATURE}/                      # Design artifacts (created per module)
│   └── design.md                         # THE single design artifact
├── tests/                                # Terraform test files (.tftest.hcl)
├── examples/                             # Usage examples
│   ├── basic/                            # Minimal configuration
│   └── complete/                         # Full-featured configuration
└── modules/                              # Submodules (optional)
```

## Key Concepts

- **Single Design Document** -- One `design.md` replaces five separate artifacts (spec, plan, contracts, data model, tasks). Variable lists appear once, resource inventories appear once, and validation rules appear once. There is nothing to get inconsistent.

- **TDD for Terraform** -- Test files are written before module code. Each test scenario in the design document maps to a `run` block with concrete assertions. Implementation is driven by making tests pass, not by following prose instructions.

- **Embedded Security** -- Security controls are a section of the design document, not a separate review phase. Every security decision is documented with CIS/Well-Architected references and translated into test assertions that run from line one.

- **Parallel Research** -- MCP tools (`search_documentation`, `search_providers`, `get_provider_details`) fetch provider docs and AWS best practices in parallel during Phase 1. Research findings feed directly into the design agent.

- **Quality Gates** -- Phase 4 runs automated validation: `terraform test`, `terraform validate`, `terraform fmt -check`, `trivy config .`, and `terraform-docs`. Critical or high findings block completion.

## Agent Architecture

Agents are subagents dispatched by orchestrator skills. Each agent has a single responsibility, reads its own inputs from disk, and writes its own outputs to disk.

| Agent | Purpose |
|-------|---------|
| `sdd-design` | Produces `design.md` from clarified requirements and research findings |
| `sdd-research` | Answers one specific research question using MCP tools |
| `tf-test-writer` | Converts design.md test scenarios into `.tftest.hcl` files |
| `tf-task-executor` | Implements one checklist item from design.md |

## Skill Architecture

Skills provide domain knowledge and orchestration logic, loaded into agent context as needed.

### Orchestrators

| Skill | Purpose |
|-------|---------|
| `tf-plan-module` | Full 4-phase workflow entry point: Understand, Design, Build+Test, Validate |
| `tf-implement-module` | TDD-aware implementation: write tests first, run after each phase |
| `tf-e2e-test-module` | Automated E2E test harness: runs full workflow cycle with test defaults |

### Domain Knowledge — User-Invocable

| Skill | Purpose |
|-------|---------|
| `tf-architecture-patterns` | Patterns for module architecture -- composition, conditionals, policy |
| `tf-implementation-patterns` | Patterns for Terraform code -- locals, for_each, dynamic blocks, lifecycle |
| `terraform-test` | Terraform test patterns -- plan-only, conditional resources, validation, mocks |
| `terraform-style-guide` | Code style conventions -- naming, formatting, file organization |

### Domain Knowledge — Background

| Skill | Purpose |
|-------|---------|
| `tf-domain-taxonomy` | 8-category taxonomy for scanning requirements and identifying gaps |
| `tf-research-heuristics` | Strategies for MCP research -- tools, order, what to look for |
| `tf-report-template` | Validation results summary template |
| `tf-security-baselines` | CIS/NIST security baselines and risk rating framework |

## Testing Strategy

Module testing follows a TDD approach. Tests are written before module code and drive the implementation.

1. **Write tests first** from `design.md` test scenarios. Each scenario becomes a `run` block in a `.tftest.hcl` file. Each assertion in the design maps 1:1 to an `assert` block.
2. **Plan-only tests** (`command = plan`) for fast feedback without cloud access. Validate resource configuration, conditional creation, variable validation, and security defaults.
3. **Run tests after each implementation phase.** Expect failures early -- that is the point of TDD. Track progress by counting passing assertions.
4. **Variable validation tests** use `expect_failures` to verify that invalid inputs are rejected with clear error messages.
5. **Security assertions exist from line 1.** Encryption, public access blocks, TLS enforcement, and least-privilege policies are tested before any feature code is written.

```
tests/
  basic.tftest.hcl         # Secure defaults, features disabled, core outputs
  complete.tftest.hcl       # All features enabled, security assertions
  validation.tftest.hcl     # All invalid input cases (expect_failures)
```

## Contributing

Follow the constitution at `.foundations/memory/constitution.md`. Use `/tf-plan-module` for new modules. All agents and skills follow the conventions documented in `AGENTS.md`.

When adding new agents or skills:
- Agent definitions go in `.claude/agents/` as Markdown files
- Skill definitions go in `.claude/skills/{skill-name}/SKILL.md`
- Update `AGENTS.md` with the new component

## License

See [LICENSE](./LICENSE) file.
