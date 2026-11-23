locals {
  # Use the already chosen unique suffix in Academy without changing its existing inputs.
  lab_backup_bucket = var.learner_lab == null ? null : "${var.resource_prefix}-backups-${trimprefix(var.learner_lab.bucket_name, "${var.resource_prefix}-bootstrap-")}"
  backup_bucket     = var.learner_lab == null ? aws_s3_bucket.backups[0].bucket : local.lab_backup_bucket
  backup_bucket_arn = var.learner_lab == null ? aws_s3_bucket.backups[0].arn : "arn:${split(":", data.aws_iam_instance_profile.learner[0].arn)[1]}:s3:::${local.lab_backup_bucket}"
  backup_object_arn = "${local.backup_bucket_arn}/postgresql/campus-*.dump"
  backup_actions    = ["s3:GetObject", "s3:PutObject"]
  backup_agent_role = var.learner_lab == null ? aws_iam_role.node["agent"].arn : data.aws_iam_instance_profile.learner[0].role_arn
  backup_agent_ip   = cidrhost(local.subnet_cidrs.private, 10)
  backup_permissions = [
    {
      Sid      = "DatabaseBackups"
      Effect   = "Allow"
      Action   = local.backup_actions
      Resource = local.backup_object_arn
    },
    {
      Sid      = "UseBackupKeyThroughS3"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = one(aws_kms_key.backups[*].arn)
      Condition = {
        StringEquals = {
          "kms:ViaService"                   = "s3.${var.aws_region}.amazonaws.com"
          "kms:EncryptionContext:aws:s3:arn" = local.backup_bucket_arn
        }
      }
    }
  ]
  backup_endpoint_access = {
    Sid       = "DatabaseAgentBackups"
    Effect    = "Allow"
    Principal = "*"
    Action    = local.backup_actions
    Resource  = local.backup_object_arn
    Condition = {
      ArnEquals    = { "aws:PrincipalArn" = local.backup_agent_role }
      StringEquals = { "aws:Ec2InstanceSourceVpc" = aws_vpc.project.id }
      IpAddress = {
        "aws:VpcSourceIp"                  = local.backup_agent_ip
        "aws:Ec2InstanceSourcePrivateIPv4" = local.backup_agent_ip
      }
    }
  }
}

resource "aws_s3_bucket" "backups" {
  count = var.learner_lab == null ? 1 : 0

  bucket_prefix = "${var.resource_prefix}-backups-"
  force_destroy = false
  tags          = { Name = "${var.resource_prefix}-backups" }
}

# Academy denies the Object Lock read performed by aws_s3_bucket. Reuse the
# owner/tag checks used for bootstrap, with strict empty-bucket deletion here.
resource "terraform_data" "backup_bucket" {
  count = var.learner_lab == null ? 0 : 1
  input = {
    bucket  = local.lab_backup_bucket
    owner   = split(":", data.aws_iam_instance_profile.learner[0].arn)[4]
    region  = var.aws_region
    project = var.resource_prefix
    python  = var.learner_lab.python_executable
    helper  = abspath("${path.module}/bootstrap/academy_bucket.py")
  }
  triggers_replace = [local.lab_backup_bucket, var.aws_region, split(":", data.aws_iam_instance_profile.learner[0].arn)[4]]

  provisioner "local-exec" {
    interpreter = [self.input.python, self.input.helper]
    command     = "ensure"
    environment = {
      ACADEMY_BUCKET  = self.input.bucket
      ACADEMY_OWNER   = self.input.owner
      ACADEMY_REGION  = self.input.region
      ACADEMY_PROJECT = self.input.project
      ACADEMY_PURPOSE = "backups"
    }
  }
  provisioner "local-exec" {
    when        = destroy
    interpreter = [self.input.python, self.input.helper]
    command     = "destroy"
    environment = {
      ACADEMY_BUCKET  = self.input.bucket
      ACADEMY_OWNER   = self.input.owner
      ACADEMY_REGION  = self.input.region
      ACADEMY_PROJECT = self.input.project
      ACADEMY_PURPOSE = "backups"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = local.backup_bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  depends_on              = [terraform_data.backup_bucket]
}

resource "aws_kms_key" "backups" {
  count = var.learner_lab == null ? 1 : 0

  description             = "Encrypt PostgreSQL backup archives"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "${var.resource_prefix}-backups-key" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = local.backup_bucket
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.learner_lab == null ? aws_kms_key.backups[0].arn : null
    }
  }
  depends_on = [terraform_data.backup_bucket]
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = local.backup_bucket
  rule {
    id     = "expire-postgresql-after-seven-days"
    status = "Enabled"
    filter {
      prefix = "postgresql/"
    }
    expiration {
      days = 7
    }
  }
  depends_on = [terraform_data.backup_bucket]
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = local.backup_bucket
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RequireTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.backup_bucket_arn, "${local.backup_bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "NodeCredentialsRequireBackupEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.backup_bucket_arn, "${local.backup_bucket_arn}/*"]
        Condition = {
          ArnEquals       = { "aws:PrincipalArn" = local.backup_agent_role }
          Null            = { "ec2:SourceInstanceARN" = "false" }
          StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.bootstrap.id }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.backups]
}
