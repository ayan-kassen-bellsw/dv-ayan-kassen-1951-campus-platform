locals {
  bootstrap_bucket_name = var.learner_lab == null ? aws_s3_bucket.bootstrap[0].bucket : var.learner_lab.bucket_name
  bootstrap_bucket_arn  = var.learner_lab == null ? aws_s3_bucket.bootstrap[0].arn : "arn:${split(":", data.aws_iam_instance_profile.learner[0].arn)[1]}:s3:::${var.learner_lab.bucket_name}"
  k3s_version           = trimspace(file("${path.module}/bootstrap/version"))
  release_filenames     = toset(["k3s", "k3s-airgap-images-amd64.tar.zst", "sha256sum-amd64.txt"])
  release_hashes = {
    for digest in regexall("(?m)^([0-9a-f]{64})  ([a-z0-9.-]+)\\r?$", file("${path.module}/bootstrap/release.sha256")) :
    digest[1] => digest[0]
  }
  release_object_arns = [
    for filename in local.release_filenames : "${local.bootstrap_bucket_arn}/releases/${local.k3s_version}/${filename}"
  ]
  token_object_arn = "${local.bootstrap_bucket_arn}/cluster/agent-token"
}

resource "aws_s3_bucket" "bootstrap" {
  count = var.learner_lab == null ? 1 : 0

  bucket_prefix = "${var.resource_prefix}-bootstrap-"
  # This bucket contains disposable bootstrap files and the runtime-created token.
  force_destroy = true
  tags          = { Name = "${var.resource_prefix}-bootstrap" }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = local.bootstrap_bucket_name
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  depends_on = [terraform_data.bootstrap_bucket]
}

resource "aws_kms_key" "bootstrap" {
  count = var.learner_lab == null ? 1 : 0

  description             = "Encrypt the private k3s bootstrap release and agent token"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "${var.resource_prefix}-bootstrap-key" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = local.bootstrap_bucket_name

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.learner_lab == null ? aws_kms_key.bootstrap[0].arn : null
    }
  }

  depends_on = [terraform_data.bootstrap_bucket]
}

resource "aws_s3_bucket_policy" "bootstrap" {
  bucket = local.bootstrap_bucket_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid       = "RequireTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bootstrap_bucket_arn, "${local.bootstrap_bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }], local.lab_bucket_deny)
  })
  depends_on = [aws_s3_bucket_public_access_block.bootstrap]
}

resource "aws_s3_object" "release" {
  for_each = local.release_filenames

  bucket      = local.bootstrap_bucket_name
  key         = "releases/${local.k3s_version}/${each.key}"
  source      = "${path.module}/.artifacts/${local.k3s_version}/${each.key}"
  source_hash = local.release_hashes[each.key]

  depends_on = [
    aws_s3_bucket_policy.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
  ]
}

resource "aws_vpc_endpoint" "bootstrap" {
  vpc_id            = aws_vpc.project.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for table in aws_route_table.project : table.id]

  # Gateway endpoints require Principal "*" and support restricting it by role ARN.
  policy = var.learner_lab != null ? local.lab_endpoint_policy : jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.ecr_s3_read,
      {
        Sid       = "ReadBootstrap"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = concat(local.release_object_arns, [local.token_object_arn])
        Condition = { ArnEquals = { "aws:PrincipalArn" = [for role in aws_iam_role.node : role.arn] } }
      },
      {
        Sid       = "PublishAgentToken"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = local.token_object_arn
        Condition = { ArnEquals = { "aws:PrincipalArn" = aws_iam_role.node["server"].arn } }
      },
    ]
  })

  tags = { Name = "${var.resource_prefix}-bootstrap-s3" }
}

resource "aws_vpc_security_group_egress_rule" "bootstrap_s3" {
  security_group_id = aws_security_group.workload["app"].id
  prefix_list_id    = aws_vpc_endpoint.bootstrap.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to the regional S3 service through the bootstrap gateway endpoint"
  tags              = { Name = "${var.resource_prefix}-bootstrap-s3-out" }
}
