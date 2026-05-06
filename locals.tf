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

  # NOTE: local.kms_key_arn_resolved (the BYO-or-self-created key ARN actually
  # used by the agent + log groups) is added in Item B alongside aws_kms_key.this.
  # Terraform parses references at validate time, so we cannot reference an
  # undeclared resource here even guarded by try().

  # Optional guardrail ARN, computed for the agent inline policy. Empty when
  # var.guardrail_id == "" so no statement is appended in that case.
  guardrail_arn = var.guardrail_id == "" ? "" : "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:guardrail/${var.guardrail_id}"

  # Log group name for the agent — referenced from both the log group resource
  # itself and the KMS key policy's kms:EncryptionContext condition.
  agent_log_group_name = "/aws/bedrock/agents/${var.agent_name}"
  agent_log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.agent_log_group_name}"
}
