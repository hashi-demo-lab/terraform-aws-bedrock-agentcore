###############################################################################
# examples/complete/kms.tf
#
# Consumer-managed (BYO) KMS CMK + alias passed into the module via
# kms_key_arn. Split out of main.tf to keep each example file under the
# constitution §2.1 file-size cap.
#
# Key policy must allow:
#   - root account (full KMS admin)
#   - bedrock.amazonaws.com (agent at-rest encryption)
#   - logs.<region>.amazonaws.com (CloudWatch log group encryption)
#   - aoss.amazonaws.com (OpenSearch Serverless collection at-rest encryption)
###############################################################################

data "aws_iam_policy_document" "byo_kms_key" {
  statement {
    sid       = "EnableRootAccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowBedrockAgentAndLogsAndAoss"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "bedrock.amazonaws.com",
        "logs.${data.aws_region.current.region}.amazonaws.com",
        "aoss.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key" "byo" {
  description             = "BYO CMK for bedrock-agentcore complete-example agent"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.byo_kms_key.json

  tags = {
    Name        = "complete-demo-byo"
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}

resource "aws_kms_alias" "byo" {
  name          = "alias/complete-demo-byo"
  target_key_id = aws_kms_key.byo.key_id
}
