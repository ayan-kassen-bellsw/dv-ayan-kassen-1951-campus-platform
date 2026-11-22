variable "ami_id" {
  description = "Optional AL2023 x86_64 AMI ID to use instead of the current public SSM parameter."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-([0-9a-f]{8}|[0-9a-f]{17})$", var.ami_id))
    error_message = "Provide a valid AMI ID or leave ami_id unset."
  }
}

data "aws_ssm_parameter" "al2023" {
  count           = var.ami_id == null ? 1 : 0
  name            = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  with_decryption = false
}

locals {
  node_ami_id      = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023[0].insecure_value
  server_ip        = cidrhost(local.subnet_cidrs.public, 10)
  node_roles       = toset(["server", "agent"])
  custom_iam_roles = var.learner_lab == null ? local.node_roles : toset([])
  node_user_data = {
    for role in local.node_roles : role => templatefile("${path.module}/bootstrap/cloud-init.sh.tftpl", {
      role            = role
      bucket          = local.bootstrap_bucket_name
      region          = var.aws_region
      version         = local.k3s_version
      server_ip       = local.server_ip
      manifest_sha256 = local.release_hashes["sha256sum-amd64.txt"]
    })
  }
}

resource "aws_iam_role" "node" {
  for_each = local.custom_iam_roles

  name = "${var.resource_prefix}-k3s-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "bootstrap" {
  for_each = local.custom_iam_roles

  name = "${var.resource_prefix}-${each.key}-bootstrap"
  role = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPinnedRelease"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = local.release_object_arns
      },
      {
        Sid      = "ClusterAgentToken"
        Effect   = "Allow"
        Action   = each.key == "server" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
        Resource = local.token_object_arn
      },
      {
        Sid    = "UseBootstrapKeyThroughS3"
        Effect = "Allow"
        # Checksum-enabled SSE-KMS downloads can require both KMS permissions.
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.bootstrap[0].arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                   = "s3.${var.aws_region}.amazonaws.com"
            "kms:EncryptionContext:aws:s3:arn" = local.bootstrap_bucket_arn
          }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.custom_iam_roles
  name     = "${var.resource_prefix}-k3s-${each.key}"
  role     = aws_iam_role.node[each.key].name
}

resource "aws_instance" "server" {
  ami                         = local.node_ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.project["public"].id
  private_ip                  = local.server_ip
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.workload["ingress"].id, aws_security_group.workload["app"].id]
  iam_instance_profile        = var.learner_lab == null ? aws_iam_instance_profile.node["server"].name : data.aws_iam_instance_profile.learner[0].name
  user_data                   = var.learner_lab == null ? local.node_user_data.server : local.lab_node_user_data.server
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 16
    tags        = { Name = "${var.resource_prefix}-k3s-server-root" }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "${var.resource_prefix}-k3s-server" }

  depends_on = [
    aws_iam_role_policy.bootstrap,
    aws_s3_object.release,
    aws_vpc_security_group_egress_rule.bootstrap_s3,
    aws_vpc_security_group_ingress_rule.private,
    aws_vpc_security_group_egress_rule.private,
    aws_route_table_association.project,
    aws_route.public_internet,
  ]
}

resource "aws_instance" "agent" {
  ami                         = local.node_ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.project["private"].id
  private_ip                  = cidrhost(local.subnet_cidrs.private, 10)
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.workload["app"].id]
  iam_instance_profile        = var.learner_lab == null ? aws_iam_instance_profile.node["agent"].name : data.aws_iam_instance_profile.learner[0].name
  user_data                   = var.learner_lab == null ? local.node_user_data.agent : local.lab_node_user_data.agent
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 16
    tags        = { Name = "${var.resource_prefix}-k3s-agent-root" }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "${var.resource_prefix}-k3s-agent" }

  # A rebuilt single server has a new cluster CA and Kubernetes state.
  lifecycle {
    replace_triggered_by = [aws_instance.server.id]
  }

  depends_on = [aws_instance.server]
}
