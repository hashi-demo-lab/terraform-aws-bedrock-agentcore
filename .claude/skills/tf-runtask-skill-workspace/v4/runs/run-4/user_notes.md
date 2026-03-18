# User Notes

## Uncertainty
- The task stage exists with status "passed" but has zero task results. This could mean the run task integration was configured but the external service returned no results, or the task was removed after the run started.
- The org name "hashi-demos-apj" was provided in the prompt but is not needed by the script (it uses the run ID directly). The run was confirmed to exist on app.terraform.io.

## Needs Human Review
- Verify whether the workspace is expected to have active run tasks producing results. The empty task results may indicate a misconfiguration or a run task that was recently added/removed.

## Workarounds
- None needed. The script and MCP tool both worked as expected.

## Suggestions
- None
