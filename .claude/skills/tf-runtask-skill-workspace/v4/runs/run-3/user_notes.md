# User Notes

## Uncertainty
- Cannot distinguish between "run never existed" vs "run was deleted" vs "token lacks access" — the API returns the same 404 for all three cases.

## Needs Human Review
- Verify the run ID `run-NONEXISTENT12345` is correct. If it was copy-pasted, check for truncation or extra characters.
- Confirm the TFE_TOKEN has read access to the workspace that should contain this run.

## Workarounds
- None needed — the script and MCP tool both handled the 404 gracefully with clear error messages.

## Suggestions
- None. The skill's error handling correctly surfaced the 404 with actionable context (run ID included in error message).
