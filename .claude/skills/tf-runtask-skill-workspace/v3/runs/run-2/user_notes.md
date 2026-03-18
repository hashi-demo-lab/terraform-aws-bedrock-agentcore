# User Notes

## Uncertainty
- The Policy outcome shows severity "Gated" but the overall task enforcement is "advisory". The run was applied despite the gated policy failure. This may indicate the gated severity at the outcome level is informational only and does not override the workspace-level task enforcement setting.

## Needs Human Review
- The `cost-center` tag is missing from 22 resources. While advisory, this may indicate a tagging standard that should be addressed.
- The EC2 instance type policy requires `t2.small` but `t3.small` is deployed. Verify whether the policy should be updated to allow `t3.small`/`t4g.small` or the instance type should be changed.

## Workarounds
- None needed. The skill executed as expected.

## Suggestions
- None.
