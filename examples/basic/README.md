# basic

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_bedrock_agent"></a> [bedrock\_agent](#module\_bedrock\_agent) | ../../ | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS region for resource deployment | `string` | `"us-east-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_agent_alias_arn"></a> [agent\_alias\_arn](#output\_agent\_alias\_arn) | Full ARN of the agent alias used for invocation |
| <a name="output_agent_arn"></a> [agent\_arn](#output\_agent\_arn) | Full ARN of the Bedrock Agent |
| <a name="output_agent_id"></a> [agent\_id](#output\_agent\_id) | Unique identifier of the Bedrock Agent |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key used for encryption |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Name of the CloudWatch log group |
<!-- END_TF_DOCS -->
