# v3 Improvements over v2

## Changes based on grader and comparator feedback

1. **MCP context always fetched**: v2→v3 blind comparison on eval 3 showed v2 won because its executor happened to call `get_run_details` while v2's skill text treated it as optional. v3 strengthened the "Enriching with MCP run context" section to make it clear: always call `get_run_details` after fetching task results. This was the single biggest differentiator in blind comparisons.

2. **URL field in Tier 2 table**: Added a Link column to the task results table so users can click through to the external service's full report. The `url` field was documented but not surfaced in the presentation template.

3. **Generalized outcome handling**: Removed assumption of vendor-specific outcome names (Estimation, Policy, Recommendation). Skill now instructs to present whatever categories the task returns, making it work with any run task integration.

4. **body_html extraction guidance**: Added explicit instruction to always extract and summarize key findings from `body_html` when present, reinforcing the Tier 4 actionable insights.

5. **Tightened evals**: Added MCP run metadata assertions to evals 0, 1, and 3 — the key differentiator that v2 couldn't reliably pass.

## Remaining issue

- Eval 3 (edge case): 6/7 pass rate. The executor sometimes omits explicit numeric summary counts (Total: 0, Passed: 0...) when describing zero-results scenarios in prose. The Tier 1 instruction is clear but could be made even more prominent for edge cases.

## Expected Impact

- Consistent MCP context in every response (no more execution variance on this)
- Richer task result tables with external service links
- Works with any run task vendor, not just Apptio-Cloudability
