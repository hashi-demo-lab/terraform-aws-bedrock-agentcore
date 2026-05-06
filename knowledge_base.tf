###############################################################################
# knowledge_base.tf — Item E
#
# All resources gated on `var.enable_knowledge_base ? 1 : 0`. Split out of
# main.tf to honor the constitution §2.1 file-size cap (500 lines).
#
# Resources defined here:
#   aws_iam_role.kb                                          — count = var.enable_knowledge_base ? 1 : 0
#   aws_iam_role_policy.kb                                   — count = var.enable_knowledge_base ? 1 : 0
#   aws_opensearchserverless_security_policy.encryption      — count = var.enable_knowledge_base ? 1 : 0
#   aws_opensearchserverless_security_policy.network         — count = var.enable_knowledge_base ? 1 : 0
#   aws_opensearchserverless_collection.kb                   — count = var.enable_knowledge_base ? 1 : 0
#   aws_opensearchserverless_access_policy.kb                — count = var.enable_knowledge_base ? 1 : 0
#   time_sleep.wait_aoss_dap                                 — count = var.enable_knowledge_base ? 1 : 0
#   opensearch_index.kb                                      — count = var.enable_knowledge_base ? 1 : 0
#   aws_bedrockagent_knowledge_base.this                     — count = var.enable_knowledge_base ? 1 : 0
#   aws_bedrockagent_data_source.this                        — count = var.enable_knowledge_base ? 1 : 0
#   aws_bedrockagent_agent_knowledge_base_association.this   — count = var.enable_knowledge_base ? 1 : 0
#
# Schema notes (verified via `terraform providers schema -json`):
#   - knowledge_base_configuration, vector_knowledge_base_configuration,
#     embedding_model_configuration, bedrock_embedding_model_configuration,
#     storage_configuration, opensearch_serverless_configuration, field_mapping
#     are ALL list-typed nested blocks (nesting_mode = "list"). Written with
#     block syntax (no `=`), addressed in tests via `[0]`.
#   - data_source_configuration, s3_configuration, vector_ingestion_configuration,
#     chunking_configuration, fixed_size_chunking_configuration, and
#     server_side_encryption_configuration are list-typed blocks too.
#   - aws_bedrockagent_data_source.s3_configuration.inclusion_prefixes is
#     attribute-typed (set of strings) and is set with `=` on the inline list.
#
# Provider note (opensearch): The opensearch-project/opensearch provider must
# be configured by the CONSUMER with the AOSS collection endpoint and SigV4
# auth. The constitution forbids hard-coded provider blocks inside reusable
# modules — see examples/complete/main.tf for the pattern. The module relies on
# the inherited provider configuration at the calling root.
###############################################################################

# IAM execution role for the KB. Trust policy is in data.aws_iam_policy_document.kb_assume.
resource "aws_iam_role" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name               = local.kb_role_name
  assume_role_policy = data.aws_iam_policy_document.kb_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name   = "${local.kb_role_name}-inline"
  role   = aws_iam_role.kb[0].id
  policy = data.aws_iam_policy_document.kb_inline[0].json
}

# AOSS encryption security policy — applies to the named collection. AWS-owned
# vs CMK is selected by aws_owned_key (true) or kms_key_arn. This module's
# default uses the resolved CMK so AOSS data inherits the same key as the agent
# log group / agent. The policy targets the collection by name pattern.
resource "aws_opensearchserverless_security_policy" "encryption" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource     = ["collection/${local.kb_collection_name}"]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = false
    KmsARN      = local.kms_key_arn_resolved
  })
}

# AOSS network security policy. Default: AllowFromPublic = true so the basic
# example works without VPC plumbing. The encryption policy + IAM data-access
# policy are the security boundary; for production, set up a VPC endpoint and
# flip AllowFromPublic to false (documented in design.md and README).
resource "aws_opensearchserverless_security_policy" "network" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-net"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource     = ["collection/${local.kb_collection_name}"]
          ResourceType = "collection"
        },
        {
          Resource     = ["collection/${local.kb_collection_name}"]
          ResourceType = "dashboard"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_collection" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name = local.kb_collection_name
  type = "VECTORSEARCH"

  tags = local.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

# AOSS data-access policy (data plane). Grants the KB execution role the full
# index lifecycle on the collection and read/write on every document in the
# index — Bedrock manages the index contents internally. Principal is the KB
# role ARN, NOT the caller.
resource "aws_opensearchserverless_access_policy" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name = "${local.kb_collection_name}-dap"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = ["collection/${local.kb_collection_name}"]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DescribeCollectionItems",
            "aoss:UpdateCollectionItems",
          ]
          ResourceType = "collection"
        },
        {
          Resource = ["index/${local.kb_collection_name}/*"]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:UpdateIndex",
            "aoss:WriteDocument",
            "aoss:DeleteIndex",
          ]
          ResourceType = "index"
        }
      ]
      Principal   = [aws_iam_role.kb[0].arn]
      Description = "Bedrock KB data access for ${var.agent_name}"
    }
  ])
}

# AOSS data-access-policy propagation is eventually consistent. Without this
# pause, opensearch_index.kb (which calls the AOSS data-plane API as the
# Terraform principal-of-record) and the KB resource (which validates index
# existence) sporadically fail with AccessDeniedException on first apply. 60s
# matches the empirical recovery window documented in research-bedrock-knowledge-base.md.
resource "time_sleep" "wait_aoss_dap" {
  count = var.enable_knowledge_base ? 1 : 0

  create_duration = "60s"

  depends_on = [
    aws_opensearchserverless_access_policy.kb,
    aws_opensearchserverless_collection.kb,
  ]
}

# Pre-create the k-NN vector index so aws_bedrockagent_knowledge_base.this can
# validate the field mapping at create time. Field names MUST match the
# field_mapping block on the KB resource exactly; both are sourced from the
# same locals so they cannot drift.
#
# The opensearch provider must be configured by the consumer with the AOSS
# collection endpoint (aws_opensearchserverless_collection.kb[0].collection_endpoint)
# and aws_region; SigV4 auth signs as the caller's principal which has
# data-plane access via the AOSS data-access policy above.
resource "opensearch_index" "kb" {
  count = var.enable_knowledge_base ? 1 : 0

  name                           = local.kb_vector_index_name
  number_of_shards               = "2"
  number_of_replicas             = "0"
  index_knn                      = true
  index_knn_algo_param_ef_search = "512"

  mappings = jsonencode({
    properties = {
      (local.kb_vector_field) = {
        type      = "knn_vector"
        dimension = local.kb_embedding_dimensions
        method = {
          name       = "hnsw"
          engine     = "faiss"
          space_type = "l2"
          parameters = {
            ef_construction = 512
            m               = 16
          }
        }
      }
      (local.kb_text_field) = {
        type = "text"
      }
      (local.kb_metadata_field) = {
        type  = "text"
        index = false
      }
    }
  })

  force_destroy = true

  depends_on = [time_sleep.wait_aoss_dap]
}

# Knowledge base resource — wires embedding model + AOSS storage + IAM role.
resource "aws_bedrockagent_knowledge_base" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  name        = local.kb_collection_name
  role_arn    = aws_iam_role.kb[0].arn
  description = var.knowledge_base_description

  knowledge_base_configuration {
    type = "VECTOR"

    vector_knowledge_base_configuration {
      embedding_model_arn = local.embedding_model_arn

      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions = local.kb_embedding_dimensions
        }
      }
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"

    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb[0].arn
      vector_index_name = local.kb_vector_index_name

      field_mapping {
        vector_field   = local.kb_vector_field
        text_field     = local.kb_text_field
        metadata_field = local.kb_metadata_field
      }
    }
  }

  tags = local.tags

  depends_on = [
    opensearch_index.kb,
    aws_iam_role_policy.kb,
  ]
}

# S3 data source — chunking strategy default FIXED_SIZE 300/20% per AWS console
# default and research-bedrock-knowledge-base.md. data_deletion_policy = RETAIN
# so destroying the data source preserves embeddings (re-create points at the
# same data without re-ingestion cost).
resource "aws_bedrockagent_data_source" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  knowledge_base_id    = aws_bedrockagent_knowledge_base.this[0].id
  name                 = "${var.agent_name}-source"
  data_deletion_policy = "RETAIN"

  data_source_configuration {
    type = "S3"

    s3_configuration {
      bucket_arn         = var.knowledge_base_s3_bucket_arn
      inclusion_prefixes = length(var.knowledge_base_inclusion_prefixes) > 0 ? var.knowledge_base_inclusion_prefixes : null
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"

      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }

  server_side_encryption_configuration {
    kms_key_arn = local.kms_key_arn_resolved
  }
}

# Bind the KB to the agent's DRAFT version. Adding this resource forces a
# re-prepare of the agent (the alias's wait_after_prepare timer therefore also
# depends on this resource — see depends_on block on time_sleep.wait_after_prepare
# in main.tf).
resource "aws_bedrockagent_agent_knowledge_base_association" "this" {
  count = var.enable_knowledge_base ? 1 : 0

  agent_id             = aws_bedrockagent_agent.this.agent_id
  agent_version        = "DRAFT"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this[0].id
  description          = var.knowledge_base_description
  knowledge_base_state = "ENABLED"

  depends_on = [aws_bedrockagent_data_source.this]
}
