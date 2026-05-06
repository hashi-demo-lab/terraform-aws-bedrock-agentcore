###############################################################################
# Required: Agent identity
###############################################################################

variable "agent_name" {
  description = "Stable name for the Bedrock agent and the prefix for derived resource names (KMS alias, log groups, IAM roles, AOSS collection)."
  type        = string

  validation {
    condition     = length(var.agent_name) >= 1 && length(var.agent_name) <= 100
    error_message = "agent_name must be between 1 and 100 characters."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.agent_name))
    error_message = "agent_name must contain only letters, digits, underscores, and hyphens."
  }
}

variable "instruction" {
  description = "Natural-language instruction prompt that defines the agent's behavior. AWS API requires 40-20000 chars when prepare_agent runs."
  type        = string

  validation {
    condition     = length(var.instruction) >= 40 && length(var.instruction) <= 20000
    error_message = "instruction must be between 40 and 20000 characters."
  }
}

###############################################################################
# Optional: Agent runtime configuration
###############################################################################

variable "foundation_model" {
  description = "Bedrock foundation model ID. Default is Claude Sonnet 4. Consumer must verify model availability in target region."
  type        = string
  default     = "anthropic.claude-sonnet-4-20250514"

  validation {
    condition     = length(var.foundation_model) >= 1
    error_message = "foundation_model must be a non-empty string."
  }
}

variable "agent_alias_name" {
  description = "Name of the stable invocation alias pinned to the prepared agent version."
  type        = string
  default     = "live"

  validation {
    condition     = length(var.agent_alias_name) >= 1 && length(var.agent_alias_name) <= 100
    error_message = "agent_alias_name must be between 1 and 100 characters."
  }
}

variable "idle_session_ttl_seconds" {
  description = "Session idle timeout. Bedrock-allowed range 60-3600 seconds."
  type        = number
  default     = 600

  validation {
    condition     = var.idle_session_ttl_seconds >= 60 && var.idle_session_ttl_seconds <= 3600
    error_message = "idle_session_ttl_seconds must be between 60 and 3600."
  }
}

###############################################################################
# Optional: Code interpreter & action groups
###############################################################################

variable "enable_code_interpreter" {
  description = "Attach the AWS-managed AMAZON.CodeInterpreter action group. Region-restricted: us-east-1, us-west-2, eu-central-1 only."
  type        = bool
  default     = true
}

variable "action_group_definitions" {
  description = "Map of Lambda-backed action groups keyed by action group name. Each value provides description, target Lambda ARN, and either an OpenAPI schema (inline payload OR S3 location) or a function schema. The module creates one aws_bedrockagent_agent_action_group plus one aws_lambda_permission per entry."
  type = map(object({
    description = string
    lambda_arn  = string
    api_schema = optional(object({
      payload = optional(string)
      s3 = optional(object({
        s3_bucket_name = string
        s3_object_key  = string
      }))
    }))
    function_schema = optional(object({
      functions = list(object({
        name        = string
        description = string
        parameters = optional(map(object({
          type        = string
          description = string
          required    = optional(bool, false)
        })))
      }))
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.action_group_definitions :
      (v.api_schema != null) != (v.function_schema != null)
    ])
    error_message = "Each action_group_definitions entry must set exactly one of api_schema or function_schema."
  }

  validation {
    condition = alltrue([
      for k, v in var.action_group_definitions :
      v.api_schema == null ? true : ((v.api_schema.payload != null) != (v.api_schema.s3 != null))
    ])
    error_message = "When api_schema is set, exactly one of payload or s3 must be set."
  }
}

###############################################################################
# Optional: Knowledge base
###############################################################################

variable "enable_knowledge_base" {
  description = "When true, provision the AOSS-backed knowledge base, IAM role, vector index, KB resource, S3 data source, and agent association."
  type        = bool
  default     = false
}

variable "knowledge_base_s3_bucket_arn" {
  description = "ARN of the consumer-supplied S3 bucket containing source documents for the knowledge base. Module never creates the bucket."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_knowledge_base || (length(var.knowledge_base_s3_bucket_arn) > 0 && can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$", var.knowledge_base_s3_bucket_arn)))
    error_message = "knowledge_base_s3_bucket_arn is required when enable_knowledge_base is true and must match ^arn:aws[a-z-]*:s3:::[a-z0-9.-]+$."
  }
}

variable "knowledge_base_inclusion_prefixes" {
  description = "Optional S3 key prefixes to restrict which objects in the bucket are ingested. When set, S3 IAM permissions are scoped via s3:prefix."
  type        = list(string)
  default     = []
}

variable "knowledge_base_s3_kms_key_arn" {
  description = "Optional CMK ARN if the source S3 bucket uses a customer-managed key; the KB role is granted kms:Decrypt on this key."
  type        = string
  default     = ""

  validation {
    condition     = var.knowledge_base_s3_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.knowledge_base_s3_kms_key_arn))
    error_message = "knowledge_base_s3_kms_key_arn must be empty or match ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$."
  }
}

variable "knowledge_base_embedding_model_id" {
  description = "Embedding model ID for vectorization. Default Titan v2 at 1024 dimensions."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"

  validation {
    condition     = length(var.knowledge_base_embedding_model_id) >= 1
    error_message = "knowledge_base_embedding_model_id must be a non-empty string."
  }
}

variable "knowledge_base_description" {
  description = "Natural-language description used by the agent's planner to decide when to query the KB. This is functional, not cosmetic."
  type        = string
  default     = "Use this knowledge base to retrieve relevant context from the customer document corpus."

  validation {
    condition     = length(var.knowledge_base_description) >= 1 && length(var.knowledge_base_description) <= 1000
    error_message = "knowledge_base_description must be between 1 and 1000 characters."
  }
}

###############################################################################
# Optional: API Gateway HTTP front-door
###############################################################################

variable "enable_api_gateway" {
  description = "When true, provision an HTTP API + invoker Lambda + access log group. The route is unauthenticated by default; consumer attaches authorizer using exposed outputs."
  type        = bool
  default     = false
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests-per-second throttle on the API stage."
  type        = number
  default     = 100

  validation {
    condition     = var.api_throttling_rate_limit > 0 && var.api_throttling_rate_limit <= 10000
    error_message = "api_throttling_rate_limit must be greater than 0 and at most 10000."
  }
}

variable "api_throttling_burst_limit" {
  description = "Token-bucket burst limit on the API stage."
  type        = number
  default     = 200

  validation {
    condition     = var.api_throttling_burst_limit > 0 && var.api_throttling_burst_limit <= 10000
    error_message = "api_throttling_burst_limit must be greater than 0 and at most 10000."
  }
}

variable "cors_configuration" {
  description = "Optional CORS configuration for the HTTP API. Disabled when null (default). Setting allow_origins = [\"*\"] is a security smell; document tradeoff in README."
  type = object({
    allow_origins = list(string)
    allow_methods = list(string)
    allow_headers = list(string)
    max_age       = optional(number, 0)
  })
  default = null
}

###############################################################################
# Optional: Guardrail association
###############################################################################

variable "guardrail_id" {
  description = "Optional consumer-provided Bedrock Guardrail identifier to bind to the agent. Module does NOT create the guardrail in v1."
  type        = string
  default     = ""

  validation {
    condition     = var.guardrail_id == "" || can(regex("^[a-z0-9]+$", var.guardrail_id))
    error_message = "guardrail_id must be empty or match ^[a-z0-9]+$ (lowercase alphanumerics only)."
  }
}

variable "guardrail_version" {
  description = "Guardrail version to pin. Defaults to DRAFT (mutable); pin to a numbered version in production examples."
  type        = string
  default     = "DRAFT"

  validation {
    condition     = var.guardrail_id == "" || can(regex("^([0-9]+|DRAFT)$", var.guardrail_version))
    error_message = "guardrail_version must match ^([0-9]+|DRAFT)$ when guardrail_id is set."
  }
}

###############################################################################
# Optional: Encryption, logging, lifecycle
###############################################################################

variable "kms_key_arn" {
  description = "Bring-your-own KMS CMK ARN. When empty, the module creates one with rotation enabled. Encryption is non-negotiable; this only controls key ownership."
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or match ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$."
  }
}

variable "log_retention_days" {
  description = "Retention for all CloudWatch log groups created by the module. Validated against CloudWatch Logs allowed values."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the CloudWatch Logs allowed retention values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653."
  }
}

variable "wait_after_prepare_seconds" {
  description = "Delay between the final PrepareAgent and CreateAgentAlias to work around eventual-consistency on agent_version. Set 0 to disable."
  type        = number
  default     = 10

  validation {
    condition     = var.wait_after_prepare_seconds >= 0 && var.wait_after_prepare_seconds <= 120
    error_message = "wait_after_prepare_seconds must be between 0 and 120."
  }
}

variable "force_destroy" {
  description = "When true, sets skip_resource_in_use_check = true on action groups and the agent so terraform destroy can run while the alias references them. Off by default for safety."
  type        = bool
  default     = false
}

###############################################################################
# Required: Organizational tags
###############################################################################

variable "environment" {
  description = "Required organizational tag identifying deployment environment. Applied to every taggable resource via local.required_tags."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox", "test"], var.environment)
    error_message = "environment must be one of: dev, staging, prod, sandbox, test."
  }
}

variable "owner" {
  description = "Required organizational tag identifying the owning team or person (e.g., team-genai@example.com)."
  type        = string

  validation {
    condition     = length(var.owner) >= 1 && length(var.owner) <= 256
    error_message = "owner must be between 1 and 256 characters."
  }
}

variable "cost_center" {
  description = "Required organizational tag identifying the cost center for chargeback."
  type        = string

  validation {
    condition     = length(var.cost_center) >= 1 && length(var.cost_center) <= 64
    error_message = "cost_center must be between 1 and 64 characters."
  }
}

variable "project" {
  description = "Required organizational tag identifying the project for grouping and reporting."
  type        = string

  validation {
    condition     = length(var.project) >= 1 && length(var.project) <= 128
    error_message = "project must be between 1 and 128 characters."
  }
}

variable "tags" {
  description = "Free-form additional tags merged with required tags and Name / ManagedBy = \"terraform\" defaults. Consumer-provided keys override module defaults."
  type        = map(string)
  default     = {}
}
