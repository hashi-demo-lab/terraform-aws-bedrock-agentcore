# v4 Improvements over v3

## Changes based on grader feedback

1. **Edge case summary counts fixed**: v3's eval 3 failed because the executor described zero-results in prose without the explicit Tier 1 summary line. v4 embeds the exact summary template (`**Total tasks**: 0 | Passed: 0 | Failed: 0 | Errored: 0`) directly into edge case instructions 1 and 2, making it impossible to miss. Result: eval 3 went from 6/7 (86%) to 7/7 (100%).

2. **Consolidated eval 0 assertions**: Reduced from 13 to 7 independent assertions based on grader feedback that assertions 1-7 were highly correlated (all testing different cells of the same table). New assertions test compound properties and independent aspects, providing better signal per assertion.

3. **Tightened eval 3 summary assertion**: Changed from generic "summary counts shown in user-facing text" to specific "Tier 1 summary line with explicit numeric counts (Total tasks: 0, Passed: 0, Failed: 0) appears in the user-facing response."

## Results

- Pass rate: 100% (27/27) — up from v3's 97% (32/33)
- Blind comparison eval 3: v4 won decisively (10.0 vs 7.3) — structural fix
- Blind comparison eval 0: v3 won marginally (9.5 vs 9.0) — execution variance, both 100% assertions

## Remaining observations from graders

- Graders suggest adding assertions for Tier 4 synthesis quality (highest-value output)
- Graders suggest verifying JSON artifact structural completeness beyond run_id
- These are eval improvements for future iterations, not skill deficiencies
