###############################################################################
# Locals: required tags, derived ARNs, computed conditional-creation flags.
###############################################################################

locals {
  # Required organizational tags. Consumer-supplied keys via var.tags merge but
  # cannot override the four required tags or the Name / ManagedBy defaults.
  required_tags = {
    Name        = var.agent_name
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = var.cost_center
    Project     = var.project
  }

  # Final tag map applied to every taggable resource. Required tags listed
  # second so they win over any conflicting consumer-supplied keys.
  tags = merge(var.tags, local.required_tags)

  # Computed conditional-creation flags. Centralised here so resource blocks
  # stay readable and the create/byo decision is expressed in exactly one place.
  create_kms = var.kms_key_arn == ""

  # Derived ARN context. Use data sources rather than hard-coded "aws" partition
  # so the module works in aws-cn and aws-us-gov.
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Bedrock foundation model ARN built from partition + region + model id.
  # Used to scope bedrock:InvokeModel* in the agent execution role policy.
  foundation_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.foundation_model}"

  # Optional embedding model ARN for the knowledge base IAM policy. Same shape
  # as foundation_model_arn; only referenced when enable_knowledge_base = true.
  embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.knowledge_base_embedding_model_id}"

  # BYO-or-self-created KMS key ARN resolved into a single value. When the
  # caller passes var.kms_key_arn the BYO ARN wins; otherwise the module-managed
  # aws_kms_key.this[0].arn is used. Reference this everywhere downstream
  # (agent customer_encryption_key_arn, log group kms_key_id, IAM policy).
  kms_key_arn_resolved = local.create_kms ? aws_kms_key.this[0].arn : var.kms_key_arn

  # Optional guardrail ARN, computed for the agent inline policy. Empty when
  # var.guardrail_id == "" so no statement is appended in that case.
  guardrail_arn = var.guardrail_id == "" ? "" : "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:guardrail/${var.guardrail_id}"

  # Log group name for the agent — referenced from both the log group resource
  # itself and the KMS key policy's kms:EncryptionContext condition.
  agent_log_group_name = "/aws/bedrock/agents/${var.agent_name}"
  agent_log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.agent_log_group_name}"

  # Flattened list of action-group Lambda ARNs (entries with a non-null
  # lambda_arn). Drives the conditional InvokeActionGroupLambdas statement in
  # the agent inline policy. Empty list -> statement is omitted entirely.
  action_group_lambda_arns = [
    for k, v in var.action_group_definitions :
    v.lambda_arn if try(v.lambda_arn, null) != null
  ]

  # Region+account-scoped knowledge-base ARN pattern used by the agent inline
  # policy to authorize bedrock:Retrieve / RetrieveAndGenerate. Using a pattern
  # rather than the live aws_bedrockagent_knowledge_base.this[0].arn avoids
  # creating a forward reference to Item E (which would break terraform
  # validate today). The KB this module creates lives in the same account and
  # region under the name "${var.agent_name}-kb", so the wildcard does not
  # over-grant in practice.
  kb_arn_pattern = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"

  # Derived role + alias names so the resource block stays terse.
  # var.agent_name accepts up to 100 chars (per Bedrock API), but downstream
  # AWS resources have shorter name limits:
  #   - IAM role name: 64 chars max -> prefix "bedrock-agent-" (14) + 50 = 64
  #   - IAM role name: 64 chars max -> prefix "bedrock-kb-"    (11) + 53 = 64
  #   - AOSS collection: 32 chars max -> name + "-kb" (3)      = need 29
  #   - KMS alias: 256 chars max -> safely fits full name
  # We use substr() to deterministically truncate the agent_name suffix per
  # downstream resource. Truncation is purely for resource naming; the agent
  # itself receives the full var.agent_name unchanged.
  agent_name_iam_safe  = substr(var.agent_name, 0, 50)
  agent_name_aoss_safe = substr(var.agent_name, 0, 29)

  agent_role_name = "bedrock-agent-${local.agent_name_iam_safe}"
  kms_alias_name  = "alias/bedrock-agent-${var.agent_name}"

  # Knowledge base derived names. AOSS collection names must be 3-32 chars,
  # lowercase, and start with a letter; agent_name validation already constrains
  # the character set so a simple suffix is safe.
  kb_role_name             = "bedrock-kb-${local.agent_name_iam_safe}"
  kb_collection_name       = "${local.agent_name_aoss_safe}-kb"
  kb_vector_index_name     = "bedrock-knowledge-base-default-index"
  kb_vector_field          = "bedrock-knowledge-base-default-vector"
  kb_text_field            = "AMAZON_BEDROCK_TEXT_CHUNK"
  kb_metadata_field        = "AMAZON_BEDROCK_METADATA"
  kb_embedding_dimensions  = 1024
  kb_collection_arn_prefix = "arn:${local.partition}:aoss:${local.region}:${local.account_id}:collection"
}
