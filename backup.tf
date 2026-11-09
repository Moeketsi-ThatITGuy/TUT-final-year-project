# -----------------------------------------------------------------------------
# S3 backup bucket (primary region)
#   * Private: all four Block Public Access settings on, ACLs disabled
#   * Encrypted at rest, TLS-only access, versioned, 7-day expiry
#   * App servers may only PutObject THROUGH the S3 Gateway endpoint
#     (enforced in the instance role policy, see modules/compute)
#   * force_destroy = true so `terraform destroy` empties it (demo only)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {
  provider = aws.primary
}

resource "aws_s3_bucket" "backup" {
  provider      = aws.primary
  bucket        = "${var.project_name}-db-backup-${data.aws_caller_identity.current.account_id}-${var.primary_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "backup" {
  provider                = aws.primary
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  provider = aws.primary
  bucket   = aws_s3_bucket.backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  provider = aws.primary
  bucket   = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  provider = aws.primary
  bucket   = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  provider = aws.primary
  bucket   = aws_s3_bucket.backup.id

  rule {
    id     = "expire-demo-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  provider = aws.primary
  bucket   = aws_s3_bucket.backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.backup]
}
