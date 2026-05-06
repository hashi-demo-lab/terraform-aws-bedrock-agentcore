###############################################################################
# examples/complete/s3.tf
#
# Consumer-owned S3 bucket for knowledge base source documents. Split out of
# main.tf to keep each example file under the constitution §2.1 file-size cap.
#
# The module never creates this bucket — the consumer brings it. Secure
# defaults applied here:
#   - public access blocked (all four flags)
#   - versioning enabled
#   - SSE with the BYO CMK from kms.tf, with bucket key enabled
#   - bucket policy denying non-TLS access and granting bedrock.amazonaws.com
#     scoped read with aws:SourceAccount confused-deputy guard
###############################################################################

resource "aws_s3_bucket" "kb" {
  bucket_prefix = "complete-demo-kb-"
  force_destroy = true

  tags = {
    Name        = "complete-demo-kb"
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "kb" {
  bucket = aws_s3_bucket.kb.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "kb" {
  bucket = aws_s3_bucket.kb.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kb" {
  bucket = aws_s3_bucket.kb.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.byo.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "kb_bucket" {
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.kb.arn,
      "${aws_s3_bucket.kb.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowBedrockKBRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.kb.arn,
      "${aws_s3_bucket.kb.arn}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "kb" {
  bucket = aws_s3_bucket.kb.id
  policy = data.aws_iam_policy_document.kb_bucket.json
}
