# AGENTS.md

Operational rules for the orchestrator during `/tf-plan-module` and `/tf-implement-module` workflow execution. Everything else — agent instructions, skill steps, constitution rules — lives in its own file and is loaded automatically.

## Context Management

1. **NEVER call TaskOutput** to read subagent results — EXCEPT for research agents (`tf-module-research`), whose findings are collected and forwarded to the design agent. All other agents write artifacts to disk.
2. **Verify file existence with Glob** after each agent completes — do NOT read file contents into the orchestrator.
3. **Downstream agents read their own inputs from disk.** The orchestrator passes the FEATURE path plus scope via `$ARGUMENTS`. For the design agent, `$ARGUMENTS` also includes research findings collected from research agents.
4. **Research agents: parallel foreground Task calls** (NOT `run_in_background`). Launch ALL research agents in a single message with multiple Task tool calls, then collect their in-memory findings to pass to the design agent.
5. **Minimal $ARGUMENTS**: Only pass the FEATURE path + a specific question or scope. The one exception is research findings passed to the design agent.

## Operational Notes

### GitHub Enterprise Authentication

Most `gh` commands (issue, pr, repo, etc.) do NOT accept `--hostname`. Use the `GH_HOST` environment variable instead:

```bash
export GH_HOST=github.enterprise.com
gh issue create --title "Bug report"
# Or inline:
GH_HOST=github.enterprise.com gh pr create --title "Feature"
```

Authentication requires `gh auth login --hostname <hostname>` — standard `gh auth login` only authenticates against github.com.

### Agent Output Persistence

Most agents persist output artifacts to disk. The orchestrator verifies expected files exist after each dispatch. **Exception**: Research agents (`tf-module-research`) return findings in-memory — the orchestrator collects these and passes them to the design agent via `$ARGUMENTS`.
