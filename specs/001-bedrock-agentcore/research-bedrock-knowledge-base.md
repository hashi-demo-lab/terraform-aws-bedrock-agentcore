## Research: Map the resources, prerequisites, and lifecycle for an OPTIONAL Bedrock knowledge base that integrates with a Bedrock agent via Terraform

### Decision

When `enable_knowledge_base = true`, gate the entire KB sub-stack behind `count = var.enable_knowledge_base ? 1 : 0` on each of the four resources: `aws_bedrockagent_knowledge_base`, `aws_bedrockagent_data_source`, `aws_bedrockagent_agent_knowledge_base_association`, and the KB IAM execution role + policies. Use **OpenSearch Serverless (AOSS)** as the default vector store (the most managed AWS-native option, and what the Bedrock console provisions by default), default the embedding model to `amazon.titan-embed-text-v2:0` with 1024 dimensions, default the chunking strategy to `FIXED_SIZE` (300 tokens, 20% overlap), and have the consumer bring the S3 bucket ARN via `knowledge_base_s3_bucket_arn` so the module never owns customer data. The OpenSearch Serverless collection itself (with its encryption / network / data-access policies and the vector index) should also be provisioned by the module under the same toggle, because AOSS data-access policies and the index must exist before `aws_bedrockagent_knowledge_base` will succeed (the resource validates the index at create time).

### Resources Identified

- **Primary Resource**: `aws_bedrockagent_knowledge_base` — the KB itself; binds embedding model + vector store
- **Supporting Resources** (all gated by `count = var.enable_knowledge_base ? 1 : 0`):
  - `aws_bedrockagent_data_source` — connects the KB to the consumer-supplied S3 bucket; owns chunking + parsing config
  - `aws_bedrockagent_agent_knowledge_base_association` — attaches the KB to the agent with a `description` that the agent's planner uses to decide when to query the KB (the description is functional, not cosmetic)
  - `aws_iam_role` (KB execution role) — assumed by the `bedrock.amazonaws.com` service principal with `aws:SourceAccount` + `aws:SourceArn` confused-deputy guards
  - `aws_iam_role_policy` (or `aws_iam_policy` + attachment) — `bedrock:InvokeModel` on the embedding model ARN, `s3:GetObject` + `s3:ListBucket` on the data source bucket (scoped by `s3:prefix` if `inclusion_prefixes` is set), `aoss:APIAccessAll` on the AOSS collection ARN, and `kms:Decrypt` / `kms:GenerateDataKey` if the bucket or KB uses CMKs
  - `aws_opensearchserverless_collection` (type = `VECTORSEARCH`) — the vector store
  - `aws_opensearchserverless_security_policy` x2 — one `encryption` policy (CMK or AWS-owned), one `network` policy (private/public access)
  - `aws_opensearchserverless_access_policy` (data plane) — grants the KB execution role `aoss:*` on the collection + index
  - `opensearch_index` (terraform-provider-opensearch / opensearch-project) OR a `null_resource` with `local-exec` invoking `awscurl`/`curl` against the AOSS endpoint — creates the k-NN vector index with the correct field mapping (`vector` field of dim 1024, `text` field, `metadata` field). This is the **single biggest operational gotcha**: AWS does not provide a Terraform-native resource to create an AOSS index. Most production modules either (a) take a hard dependency on the `opensearch` provider, or (b) require the consumer to pre-create the index and pass `vector_index_name`. Recommend (a) with `opensearch_index` for a fully self-contained module.
- **Key Arguments** (`aws_bedrockagent_knowledge_base`):
  - `name` (required) — KB name, must be unique per account/region, regex `^([0-9a-zA-Z][_-]?){1,100}$`
  - `role_arn` (required) — the KB execution role ARN
  - `knowledge_base_configuration` (required, single block):
    - `type = "VECTOR"`
    - `vector_knowledge_base_configuration.embedding_model_arn` — defaults to `arn:${partition}:bedrock:${region}::foundation-model/amazon.titan-embed-text-v2:0`
    - `vector_knowledge_base_configuration.embedding_model_configuration.bedrock_embedding_model_configuration.dimensions` — `1024` for Titan v2 (also supports 256, 512); set to match the AOSS index mapping
  - `storage_configuration` (required, single block):
    - `type = "OPENSEARCH_SERVERLESS"`
    - `opensearch_serverless_configuration.collection_arn` — AOSS collection ARN
    - `opensearch_serverless_configuration.vector_index_name` — must match the index created out-of-band
    - `opensearch_serverless_configuration.field_mapping.{vector_field, text_field, metadata_field}` — must match the index mapping exactly (validated at create)
- **Key Arguments** (`aws_bedrockagent_data_source`):
  - `knowledge_base_id` (required) — `aws_bedrockagent_knowledge_base.this[0].id`
  - `name` (required)
  - `data_source_configuration.type = "S3"` and `data_source_configuration.s3_configuration.bucket_arn` (required); `inclusion_prefixes` (optional list)
  - `vector_ingestion_configuration.chunking_configuration.chunking_strategy` — one of `FIXED_SIZE`, `HIERARCHICAL`, `SEMANTIC`, `NONE` (default secure choice: `FIXED_SIZE` 300 tokens / 20% overlap)
  - `vector_ingestion_configuration.parsing_configuration` (optional) — leave default (in-built parser); offer opt-in `BEDROCK_FOUNDATION_MODEL` parser for advanced PDF/image parsing (extra cost)
  - `data_deletion_policy` — `RETAIN` (default, recommended) or `DELETE` (purge embeddings on destroy)
  - `server_side_encryption_configuration.kms_key_arn` (optional) — CMK to encrypt transient/intermediate data during ingestion
- **Key Arguments** (`aws_bedrockagent_agent_knowledge_base_association`):
  - `agent_id` (required) — bound to the **DRAFT** version (the only version Terraform can mutate); the resource handles `prepare_agent` implicitly when used with the agent resource's own `prepare_agent = true`
  - `knowledge_base_id` (required)
  - `description` (required) — natural-language hint the agent uses to route queries to this KB; this is **prompt-engineering territory**, not metadata
  - `knowledge_base_state` — `ENABLED` (default) or `DISABLED`
- **Key Outputs** (suggested module exports, all `try(...[0], null)` for the optional case):
  - `knowledge_base_id` (`string`) — for cross-stack references / observability
  - `knowledge_base_arn` (`string`)
  - `knowledge_base_role_arn` (`string`) — for consumers who want to extend the policy
  - `data_source_id` (`string`) — needed to trigger ingestion via SDK/CLI (`StartIngestionJob`)
  - `opensearch_collection_arn` (`string`) — for observability / cross-account
- **Security Considerations**:
  - **IAM trust policy** on KB role MUST include `aws:SourceAccount = data.aws_caller_identity.current.account_id` and `aws:SourceArn = arn:${partition}:bedrock:${region}:${account}:knowledge-base/*` to prevent cross-account confused-deputy (Bedrock service principal is otherwise unscoped)
  - **AOSS encryption policy**: AWS-owned key by default; expose `kms_key_arn` variable for CMK
  - **AOSS network policy**: default to `AllowFromPublic = false` and require a VPC endpoint for production; for the basic example, public access is acceptable but document the trade-off
  - **AOSS data access policy**: principal MUST be the KB execution role ARN, not the consumer's caller; permissions limited to `aoss:CreateIndex`, `aoss:UpdateIndex`, `aoss:DescribeIndex`, `aoss:ReadDocument`, `aoss:WriteDocument` on the specific index, and `aoss:DescribeCollectionItems` on the collection
  - **S3 read scope**: `s3:GetObject` / `s3:ListBucket` should be conditioned on `s3:prefix` when `inclusion_prefixes` is set; never grant `s3:*`
  - **Embedding model invoke**: scope to the exact model ARN (regional), not `bedrock:InvokeModel` on `*`
  - **KMS**: if the consumer's S3 bucket uses a CMK, the KB role needs `kms:Decrypt` on that key ARN AND the key policy must allow the KB role — surface `knowledge_base_s3_kms_key_arn` (optional) as a variable so the module can build the right policy statement; document the key-policy side as a consumer responsibility
  - **Logging**: enable Bedrock model invocation logging at the account level (out of module scope, but document); for KB ingestion, CloudTrail data events on the AOSS collection are recommended

### Rationale

**Vector store choice — OpenSearch Serverless as default**: AWS Bedrock supports five vector stores for KBs: OpenSearch Serverless, Aurora PostgreSQL with pgvector (and the new Aurora-managed option), Pinecone, Redis Enterprise Cloud, and MongoDB Atlas. AOSS is the only option AWS provisions automatically when you create a KB through the console "quick create" flow, and it is the only one that requires no separate vendor account, no VPC/Aurora cluster sizing, and no third-party billing. Operationally it is also the lowest-friction: the only knobs are encryption policy, network policy, and OCU min/max (defaults to 2 OCU minimum, ~$700/mo idle — this is the one downside to flag in module docs). Aurora pgvector is cheaper at scale but requires a full RDS cluster lifecycle (subnets, parameter groups, backups, password rotation), which would balloon the module's surface area. Pinecone/MongoDB require external account credentials passed as `secret_arn`, breaking the "module owns the lifecycle" property. **Recommendation**: default to AOSS, expose `vector_store_type` as a variable for future extension but only implement `OPENSEARCH_SERVERLESS` in v1; document Aurora as a roadmap item.

**Embedding model choice — Titan Embed Text v2 at 1024 dim**: Titan v2 (`amazon.titan-embed-text-v2:0`) is GA in all Bedrock-supported regions, supports 256/512/1024 dimensions (1024 is the AWS-recommended default for English RAG), and is half the price of Cohere Embed English v3. Titan v1 (`amazon.titan-embed-text-v1`) is being phased out and has fixed 1536 dimensions. Cohere Embed Multilingual is preferred only when the corpus is non-English. Default to Titan v2 / 1024; allow override via `embedding_model_id` variable.

**Chunking strategy — `FIXED_SIZE` 300 tokens / 20% overlap**: This is the AWS console default and the empirically robust choice for general-purpose corpora. `HIERARCHICAL` is better for structured docs (legal, technical manuals) but requires tuning parent/child token sizes. `SEMANTIC` uses an LLM to find chunk boundaries — higher quality but adds per-document inference cost during ingestion and is slower. `NONE` ("no chunking") only works for already-chunked documents (e.g., one chunk per file) and is unsafe as a default. Expose `chunking_strategy` as a variable but default to `FIXED_SIZE`.

**`aws_bedrockagent_agent_knowledge_base_association` vs inline KB on agent**: The `aws_bedrockagent_agent` resource does NOT have an inline `knowledge_base` block — KB attachment is always done via the separate association resource. This is good for the optional toggle: when `enable_knowledge_base = false`, the agent resource is unchanged. The association resource has a `prepare_agent` side-effect concern: after attaching/detaching a KB, the agent must be re-prepared (a new DRAFT version published) for the change to take effect at runtime. The provider handles this implicitly when `prepare_agent = true` is set on the agent resource itself, but be aware that **toggling `enable_knowledge_base` from true→false will trigger an agent re-prepare** on the next apply.

**Optional KB design pattern**: Use `count = var.enable_knowledge_base ? 1 : 0` (NOT `for_each`) on every KB-related resource. `count` is the idiomatic Terraform pattern for a binary toggle; `for_each` would be over-engineered for a single conditional resource. All cross-references then use `aws_bedrockagent_knowledge_base.this[0].id`. Outputs use `try(aws_bedrockagent_knowledge_base.this[0].id, null)` so consumers always get a defined output (null when disabled). The KB execution role and AOSS collection are also gated by the same `count` — this is the cleanest plan when disabled (zero KB resources).

**Edge case — disabling KB mid-lifecycle**: When `enable_knowledge_base` flips from true→false, Terraform will plan to destroy the association FIRST, then the data source, then the KB, then the AOSS collection, then the IAM role. The destroy order is correct because of dependency edges. However: (a) the AOSS collection holds the embeddings — destroying it is irreversible and re-enabling the KB later means full re-ingestion (cost + time); (b) the agent will be re-prepared without the KB on the next apply, which may briefly affect production traffic if the agent is in use. Document these in the README under "Disabling the knowledge base". Consider adding a `prevent_destroy` lifecycle on the AOSS collection in the production example.

**Edge case — embedding model regional availability**: As of 2026-05, Titan Embed v2 is GA in `us-east-1`, `us-west-2`, `ap-northeast-1`, `ap-southeast-1`, `ap-southeast-2`, `eu-central-1`, `eu-west-1`, `eu-west-3`. Bedrock Agents (and therefore KB) are available in a smaller set: `us-east-1`, `us-west-2`, `ap-northeast-1`, `ap-southeast-1`, `ap-southeast-2`, `eu-central-1`. The KB region must match the agent region (no cross-region KB/agent association). Use `data.aws_partition` and `data.aws_region` to construct the embedding model ARN dynamically rather than hardcoding the partition.

**Edge case — AOSS index creation timing**: `aws_bedrockagent_knowledge_base` validates the OpenSearch index exists and has the correct field mappings at create time. If you provision the AOSS collection and the KB in the same apply, you MUST insert an explicit dependency on the index resource (and ideally a `time_sleep` of ~60 seconds after the data-access policy is created — AOSS data-access-policy propagation is eventually consistent and a known source of "AccessDeniedException" on first apply). The `opensearch_index` resource from `opensearch-project/opensearch` is the standard way; it requires configuring the `opensearch` provider with the AOSS endpoint and AWS SigV4 auth, which adds a provider dependency to the module. Alternative: surface `vector_index_name` as a required variable when KB is enabled and document that the consumer must create the index out-of-band — this is the "less magic, less moving parts" choice and many production modules take this path.

### Alternatives Considered

| Alternative | Why Not |
| ----------- | ------- |
| Aurora PostgreSQL with pgvector as default vector store | Requires full RDS cluster lifecycle (subnet group, parameter group, password rotation, backups) — multiplies the module's resource count by ~8 and pulls in networking concerns. Better as a v2 opt-in. |
| Pinecone / MongoDB Atlas / Redis as default | Requires consumer to bring third-party credentials via `aws_secretsmanager_secret`; module no longer owns the full lifecycle. Cross-cloud failure modes. Reserve for `vector_store_type` extension. |
| Inline KB block on `aws_bedrockagent_agent` | The provider does not expose this — KB attachment is always via `aws_bedrockagent_agent_knowledge_base_association`. Not an option. |
| Have the module own the S3 bucket | Violates separation-of-concerns: the bucket holds customer documents, often pre-existing or governed by a separate data-platform team. Consumer brings the bucket ARN. |
| Embedding model `amazon.titan-embed-text-v1` | Older generation, fixed 1536 dim, more expensive per token, being phased out by AWS. v2 is strictly better. |
| Embedding model `cohere.embed-english-v3` | Higher quality on some benchmarks but ~2x cost and not available in all KB-supported regions. Offer as override, not default. |
| `SEMANTIC` chunking as default | Adds LLM inference cost per document at ingestion time and is slower; not appropriate as a zero-config default. |
| `for_each = var.enable_knowledge_base ? toset(["this"]) : toset([])` | Equivalent semantics to `count`, but `count` is the idiomatic Terraform pattern for a binary toggle and produces cleaner index references (`[0]` vs `["this"]`). |
| Module pre-creates the AOSS index via `null_resource` + `local-exec` curl | Adds a runtime dependency on `awscurl` or `curl` + `aws sigv4 sign-request` on the operator's machine, breaking pure-Terraform CI. The `opensearch_index` resource from `opensearch-project/opensearch` is the cleaner option. |
| Require consumer to pre-create the AOSS collection AND index, pass both ARNs in | Maximally flexible but pushes the operational complexity onto every consumer. The whole point of `enable_knowledge_base = true` is "give me a working KB with one toggle". |
| Default `data_deletion_policy = "DELETE"` | Surprising data loss on `terraform destroy`. `RETAIN` is the safe default; consumers who want full teardown can opt in. |

### Sources

- AWS Bedrock User Guide — Knowledge bases for Amazon Bedrock: https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html
- AWS Bedrock User Guide — Vector store options: https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-setup.html
- AWS Bedrock User Guide — IAM service role for KB: https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html
- AWS Bedrock User Guide — Chunking strategies: https://docs.aws.amazon.com/bedrock/latest/userguide/kb-chunking-parsing.html
- AWS Bedrock User Guide — Titan Embeddings v2: https://docs.aws.amazon.com/bedrock/latest/userguide/titan-embedding-models.html
- AWS Bedrock User Guide — Region availability for Agents/KB: https://docs.aws.amazon.com/bedrock/latest/userguide/agents-supported.html
- AWS OpenSearch Serverless — Vector search collections: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-vector-search.html
- Terraform AWS Provider — `aws_bedrockagent_knowledge_base`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagent_knowledge_base
- Terraform AWS Provider — `aws_bedrockagent_data_source`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagent_data_source
- Terraform AWS Provider — `aws_bedrockagent_agent_knowledge_base_association`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagent_agent_knowledge_base_association
- Terraform AWS Provider — `aws_opensearchserverless_collection` / `_security_policy` / `_access_policy`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearchserverless_collection
- Terraform OpenSearch Provider — `opensearch_index`: https://registry.terraform.io/providers/opensearch-project/opensearch/latest/docs/resources/index
- Public registry pattern reference — `aws-ia/bedrock/aws` (HashiCorp/AWS-IA Bedrock module): demonstrates the AOSS + KB + agent + association composition with conditional creation via `create_kb` toggle
- AWS confused-deputy guidance for service-linked Bedrock role: https://docs.aws.amazon.com/bedrock/latest/userguide/cross-service-confused-deputy-prevention.html
