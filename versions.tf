terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = ">= 2.3"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}
