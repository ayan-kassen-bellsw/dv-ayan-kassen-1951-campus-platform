resource "aws_ecr_repository" "app" {
  name                 = "${var.resource_prefix}-scholarship-applications"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

locals {
  ecr_pull_permissions = [
    {
      Sid      = "RegistryLogin"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    },
    {
      Sid      = "ReadAppImage"
      Effect   = "Allow"
      Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Resource = aws_ecr_repository.app.arn
    },
  ]

  # ECR supplies presigned S3 URLs for layers. The signing identity belongs to ECR.
  ecr_s3_read = {
    Sid       = "ReadECRLayersFromNodes"
    Effect    = "Allow"
    Principal = "*"
    Action    = "s3:GetObject"
    Resource  = "arn:aws:s3:::prod-${var.aws_region}-starport-layer-bucket/*"
    Condition = {
      IpAddress = { "aws:VpcSourceIp" = local.node_ips }
    }
  }
}

resource "aws_vpc_endpoint" "ecr" {
  for_each = toset(["api", "dkr"])

  vpc_id              = aws_vpc.project.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.project["private"].id]
  security_group_ids  = [aws_security_group.workload["registry"].id]

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [for permission in local.ecr_pull_permissions : merge(permission, { Principal = "*" })]
  })

  tags = { Name = "${var.resource_prefix}-ecr-${each.key}" }
}
