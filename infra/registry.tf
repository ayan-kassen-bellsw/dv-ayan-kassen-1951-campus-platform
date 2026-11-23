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

  # In Academy both nodes use LabRole. Match the server that received the IMDS
  # credentials and the server ENI making the request through the private endpoint.
  ecr_list_deployments = {
    Sid      = "ListDeploymentImagesFromServer"
    Effect   = "Allow"
    Action   = ["ecr:ListImages"]
    Resource = aws_ecr_repository.app.arn
    Condition = {
      ArnEquals = { "aws:PrincipalArn" = var.learner_lab == null ? aws_iam_role.node["server"].arn : data.aws_iam_instance_profile.learner[0].role_arn }
      StringEquals = {
        "aws:SourceVpc"            = aws_vpc.project.id
        "aws:Ec2InstanceSourceVpc" = aws_vpc.project.id
      }
      IpAddress = {
        "aws:VpcSourceIp"                  = local.server_ip
        "aws:Ec2InstanceSourcePrivateIPv4" = local.server_ip
      }
    }
  }
  ecr_node_permissions = {
    server = concat(local.ecr_pull_permissions, [local.ecr_list_deployments])
    agent  = local.ecr_pull_permissions
  }

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
    Version = "2012-10-17"
    Statement = concat(
      [for permission in local.ecr_pull_permissions : merge(permission, { Principal = "*" })],
      each.key == "api" ? [merge(local.ecr_list_deployments, { Principal = "*" })] : []
    )
  })

  tags = { Name = "${var.resource_prefix}-ecr-${each.key}" }
}
