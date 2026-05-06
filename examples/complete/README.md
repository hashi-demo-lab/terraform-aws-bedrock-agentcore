# Complete Example — Every Optional Feature Enabled

This example exercises every optional capability of the
`bedrock-agentcore` module:

- A consumer-managed (BYO) KMS CMK with a key policy granting Bedrock,
  CloudWatch Logs, and OpenSearch Serverless access
- A consumer-owned S3 bucket for knowledge-base source documents, with
  versioning, public-access block, KMS-SSE, and a TLS-only bucket policy
- A knowledge base backed by an OpenSearch Serverless vector collection
  (Titan v2 embeddings, 1024 dimensions, k-NN field mapping)
- One Lambda-backed action group with a function schema (no OpenAPI
  required), a stub Python 3.12 handler, and a consumer-side bedrock
  invoke permission scoped to the agent ARN
- The AWS-managed `AMAZON.CodeInterpreter` action group
- An HTTP API Gateway front door with custom throttling, CORS, and a
  consumer-attached JWT authorizer demo
- Custom log retention (365 days) and idle-session TTL (30 minutes)

## Prerequisites

- AWS credentials with permissions to create Bedrock agents, knowledge
  bases, IAM roles, KMS keys, S3 buckets, Lambda functions, OpenSearch
  Serverless collections, API Gateway HTTP APIs, and CloudWatch log
  groups in `us-east-1`.
- Bedrock model access for `anthropic.claude-sonnet-4-20250514` AND
  `amazon.titan-embed-text-v2:0` granted in the AWS console
  (Bedrock → Model access).
- The `opensearch-project/opensearch` and `hashicorp/archive` providers
  installed (`terraform init` handles this automatically).
- A JWT issuer (Cognito, Auth0, etc.) for the API authorizer demo. The
  example uses a placeholder issuer URL; update before applying.

## Two-phase apply

The `opensearch-project/opensearch` provider must be configured with the
AOSS collection endpoint, but the collection itself is created by the
module. On first apply, this is a circular dependency — the provider
needs an endpoint that does not yet exist. There are two supported
resolutions:

### Option 1 (recommended) — target the collection first

```sh
terraform init
terraform apply -target=module.agent.aws_opensearchserverless_collection.kb
terraform apply
```

The first command provisions the AOSS collection (and everything it
depends on); the second completes the apply with the opensearch
provider properly resolved against the now-existing endpoint.

### Option 2 — disable the KB on the first apply

In `main.tf`, set `enable_knowledge_base = false` on the module call,
apply, then flip the flag to `true` and apply again. This avoids the
opensearch provider entirely on the first pass.

## Usage

```sh
# Set guardrail_id in main.tf if you have a Bedrock guardrail to bind.
# Update the JWT authorizer issuer/audience to match your real IdP.

terraform init
terraform apply -target=module.agent.aws_opensearchserverless_collection.kb
terraform apply
```

After apply, upload some sample documents to the `docs/` prefix of the
KB bucket (the prefix is configured via
`knowledge_base_inclusion_prefixes`):

```sh
aws s3 cp ./sample.pdf "s3://$(terraform output -raw kb_bucket_name)/docs/sample.pdf"
```

Trigger the first ingestion job using the `data_source_id` output:

```sh
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$(terraform output -raw knowledge_base_id)" \
  --data-source-id   "$(terraform output -raw data_source_id)"
```

Invoke the agent via the API Gateway endpoint (after attaching the JWT
authorizer to the `POST /invoke` route — see the JWT authorizer note
below):

```sh
curl -X POST \
  -H "Authorization: Bearer <your-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"input":"What is the return policy for product X?","sessionId":"demo-1"}' \
  "$(terraform output -raw api_endpoint)/invoke"
```

## JWT authorizer attachment

The module creates the API Gateway route with `authorization_type =
"NONE"` so the consumer can attach an authorizer without a circular
provider dependency. The example creates an `aws_apigatewayv2_authorizer`
resource (output: `jwt_authorizer_id`) but does NOT bind it to the route
because doing so would conflict with the route managed by the module.

To bind the authorizer in production, take one of these approaches:

1. **`terraform import` + override**: Import the module's
   `aws_apigatewayv2_route.invoke[0]` into a top-level resource block
   that sets `authorization_type = "JWT"` and
   `authorizer_id = aws_apigatewayv2_authorizer.jwt.id`.
2. **Sibling module**: Wrap this example in a second module that takes
   the `api_id`, `default_route_key`, and authorizer id, and manages the
   `aws_apigatewayv2_route` itself. The module-managed route is then
   removed from state and the sibling module owns it.
3. **Lambda authorizer pattern**: For non-JWT authentication, use
   `authorizer_type = "REQUEST"` with a Lambda authorizer and follow the
   same import-or-sibling-module pattern.

Run `terraform destroy` to remove all resources. If destroy fails on the
agent or action groups due to the alias still referencing them, set
`force_destroy = true` on the module call and re-apply once before
destroying.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.14 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.50 |
| <a name="requirement_opensearch"></a> [opensearch](#requirement\_opensearch) | >= 2.3 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | 2.7.1 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.43.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_agent"></a> [agent](#module\_agent) | ../.. | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_apigatewayv2_authorizer.jwt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_authorizer) | resource |
| [aws_cloudwatch_log_group.action_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.action_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.action_lambda_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.byo](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.byo](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_lambda_function.action](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.bedrock_invoke_action](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket.kb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_policy.kb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.kb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.kb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.kb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [archive_file.action_lambda_zip](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.action_lambda_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.action_lambda_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.byo_kms_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.kb_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

No inputs.

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_agent_alias_arn"></a> [agent\_alias\_arn](#output\_agent\_alias\_arn) | Invocation target for bedrock-agent-runtime:InvokeAgent |
| <a name="output_agent_arn"></a> [agent\_arn](#output\_agent\_arn) | Bedrock agent ARN |
| <a name="output_agent_id"></a> [agent\_id](#output\_agent\_id) | Bedrock agent identifier |
| <a name="output_agent_role_arn"></a> [agent\_role\_arn](#output\_agent\_role\_arn) | ARN of the agent execution role |
| <a name="output_api_endpoint"></a> [api\_endpoint](#output\_api\_endpoint) | HTTP API invoke URL (POST /invoke) |
| <a name="output_api_id"></a> [api\_id](#output\_api\_id) | HTTP API identifier |
| <a name="output_data_source_id"></a> [data\_source\_id](#output\_data\_source\_id) | S3 data source identifier — pass to bedrock-agent:StartIngestionJob |
| <a name="output_default_route_key"></a> [default\_route\_key](#output\_default\_route\_key) | Route key on the module's HTTP API; the consumer overrides authorization\_type to JWT and references the authorizer above |
| <a name="output_invoker_lambda_arn"></a> [invoker\_lambda\_arn](#output\_invoker\_lambda\_arn) | ARN of the bundled invoker Lambda fronting the agent |
| <a name="output_jwt_authorizer_id"></a> [jwt\_authorizer\_id](#output\_jwt\_authorizer\_id) | Identifier of the consumer-attached JWT authorizer; bind to the route via terraform import or a separate aws\_apigatewayv2\_route resource |
| <a name="output_kb_bucket_name"></a> [kb\_bucket\_name](#output\_kb\_bucket\_name) | Name of the consumer-owned KB source bucket |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the consumer-managed (BYO) KMS CMK passed into the module |
| <a name="output_knowledge_base_arn"></a> [knowledge\_base\_arn](#output\_knowledge\_base\_arn) | Knowledge base ARN |
| <a name="output_knowledge_base_id"></a> [knowledge\_base\_id](#output\_knowledge\_base\_id) | Knowledge base identifier |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | Agent CloudWatch log group name |
| <a name="output_opensearch_collection_arn"></a> [opensearch\_collection\_arn](#output\_opensearch\_collection\_arn) | AOSS vector collection ARN |
<!-- END_TF_DOCS -->
