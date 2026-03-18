# User Notes

## Uncertainty
- The Apptio-Cloudability task has a "Gated" severity on the Policy outcome, but the task-level enforcement is "advisory". The run proceeded to apply. It is unclear whether "Gated" at the outcome level has enforcement meaning or is purely informational from the external vendor.

## Needs Human Review
- The 22 resources missing the `cost-center` tag should be reviewed to determine if a default tag strategy (e.g., default_tags in the AWS provider) would resolve this broadly.
- The EC2 instance type policy violation (`t3.small` vs required `t2.small`) may be intentional or may indicate a policy that needs updating (especially given the recommendation to use `t4g.small`).

## Workarounds
- None. The skill executed as expected.

## Suggestions
- None.
