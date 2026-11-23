# Older deployments used unindexed singleton addresses.
moved {
  from = aws_s3_bucket.bootstrap
  to   = aws_s3_bucket.bootstrap[0]
}

moved {
  from = aws_kms_key.bootstrap
  to   = aws_kms_key.bootstrap[0]
}

moved {
  from = terraform_data.bootstrap_bucket
  to   = terraform_data.bootstrap_bucket[0]
}

data "aws_iam_instance_profile" "learner" {
  count = var.learner_lab == null ? 0 : 1
  name  = "LabInstanceProfile"
}

# The provider reads Object Lock on every general-purpose bucket refresh. Learner Lab
# permits basic S3 operations but denies that read. The individual controls use the AWS provider.
resource "terraform_data" "bootstrap_bucket" {
  count = var.learner_lab == null ? 0 : 1
  input = {
    bucket  = var.learner_lab.bucket_name
    owner   = split(":", data.aws_iam_instance_profile.learner[0].arn)[4]
    region  = var.aws_region
    project = var.resource_prefix
    python  = var.learner_lab.python_executable
    helper  = coalesce(var.learner_lab.bucket_helper_path, abspath("${path.module}/bootstrap/academy_bucket.py"))
  }

  lifecycle {
    precondition {
      condition     = startswith(var.learner_lab.bucket_name, "${var.resource_prefix}-bootstrap-") && length(var.learner_lab.bucket_name) > length("${var.resource_prefix}-bootstrap-")
      error_message = "Reserve a dedicated bucket in the <resource_prefix>-bootstrap-<suffix> namespace."
    }

    # Retargeting this helper in place would orphan its original bucket.
    ignore_changes = [input.bucket, input.owner, input.region, input.project]
    postcondition {
      condition = (
        self.input.bucket == var.learner_lab.bucket_name && self.input.region == var.aws_region &&
        self.input.project == var.resource_prefix && self.input.owner == split(":", data.aws_iam_instance_profile.learner[0].arn)[4]
      )
      error_message = "Destroy the existing disposable Learner Lab deployment before changing the managed bucket's identity."
    }
  }

  provisioner "local-exec" {
    interpreter = [self.input.python, self.input.helper]
    command     = "ensure"
    environment = {
      ACADEMY_BUCKET  = self.input.bucket
      ACADEMY_OWNER   = self.input.owner
      ACADEMY_REGION  = self.input.region
      ACADEMY_PROJECT = self.input.project
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
    }
  }
}

locals {
  # Both nodes use LabRole. Scope token writes to the server's issued credentials AND its ENI.
  lab_endpoint_policy = var.learner_lab == null ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.ecr_s3_read,
      local.backup_endpoint_access,
      {
        Sid       = "ReadBootstrapFromNodes"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = concat(local.release_object_arns, [local.token_object_arn])
        Condition = {
          ArnEquals    = { "aws:PrincipalArn" = data.aws_iam_instance_profile.learner[0].role_arn }
          StringEquals = { "aws:Ec2InstanceSourceVpc" = aws_vpc.project.id }
          IpAddress = {
            "aws:VpcSourceIp"                  = local.node_ips
            "aws:Ec2InstanceSourcePrivateIPv4" = local.node_ips
          }
        }
      },
      {
        Sid       = "PublishAgentTokenFromServer"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = local.token_object_arn
        Condition = {
          ArnEquals    = { "aws:PrincipalArn" = data.aws_iam_instance_profile.learner[0].role_arn }
          StringEquals = { "aws:Ec2InstanceSourceVpc" = aws_vpc.project.id }
          IpAddress = {
            "aws:VpcSourceIp"                  = local.server_ip
            "aws:Ec2InstanceSourcePrivateIPv4" = local.server_ip
          }
        }
      },
    ]
  })

  lab_bucket_deny = var.learner_lab == null ? [] : [{
    Sid       = "NodeCredentialsRequireBootstrapEndpoint"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = [local.bootstrap_bucket_arn, "${local.bootstrap_bucket_arn}/*"]
    Condition = {
      ArnEquals       = { "aws:PrincipalArn" = data.aws_iam_instance_profile.learner[0].role_arn }
      Null            = { "ec2:SourceInstanceARN" = "false" }
      StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.bootstrap.id }
    }
  }]
}
