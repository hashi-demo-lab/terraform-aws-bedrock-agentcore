# Basic Example — Bedrock Agent with Code Interpreter

This example demonstrates the minimal viable configuration of the
`bedrock-agentcore` module: a single Bedrock agent named `basic-demo`
backed by the default Claude Sonnet 4 foundation model with the AWS-managed
`AMAZON.CodeInterpreter` action group attached. The module creates and
manages a KMS CMK, the agent execution role with a least-privilege inline
policy, the agent CloudWatch log group with a 90-day retention default,
the prepared agent version, and the stable `live` alias. No knowledge base
or API Gateway front door is provisioned — see `examples/complete` for
those.

## Prerequisites

- AWS credentials with permissions to create Bedrock agents, IAM roles,
  KMS keys, and CloudWatch log groups in the target region.
- Bedrock model access for `anthropic.claude-sonnet-4-20250514` granted in
  the AWS console (Bedrock → Model access).
- Code interpreter is region-restricted to `us-east-1`, `us-west-2`, and
  `eu-central-1`; this example uses `us-east-1`.

## Usage

```sh
terraform init
terraform apply
```

After the apply completes, invoke the agent using the AWS CLI or SDK:

```sh
aws bedrock-agent-runtime invoke-agent \
  --agent-id "$(terraform output -raw agent_alias_arn | cut -d/ -f2)" \
  --agent-alias-id "$(terraform output -raw agent_alias_arn | cut -d/ -f3)" \
  --session-id "demo-session-1" \
  --input-text "What is 17 squared?" \
  /tmp/response.json
```

Run `terraform destroy` to remove all resources.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.14 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.50 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_agent"></a> [agent](#module\_agent) | ../.. | n/a |

## Resources

No resources.

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_agent_alias_arn"></a> [agent\_alias\_arn](#output\_agent\_alias\_arn) | Invocation target — pass this to bedrock-agent-runtime:InvokeAgent. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the module-created KMS CMK used for at-rest encryption. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Name of the agent CloudWatch log group. |
<!-- END_TF_DOCS -->
