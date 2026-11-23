locals {
  security_groups = {
    ingress  = "Public k3s server running the ingress controller"
    app      = "Cluster nodes that run scholarship application pods"
    database = "Private PostgreSQL network interface"
    registry = "Private ECR interface endpoints"
  }

  # These are new connections. AWS security groups allow their return traffic.
  private_flows = {
    ecr = {
      source      = "app"
      destination = "registry"
      protocol    = "tcp"
      port        = 443
      description = "Cluster nodes pulling images through ECR interface endpoints"
    }
    k3s-api = {
      source      = "app"
      destination = "ingress"
      protocol    = "tcp"
      port        = 6443
      description = "K3s node registration and API access"
    }
    flannel-vxlan = {
      source      = "app"
      destination = "app"
      protocol    = "udp"
      port        = 8472
      description = "Flannel VXLAN traffic between cluster nodes"
    }
    kubelet-metrics = {
      source      = "app"
      destination = "app"
      protocol    = "tcp"
      port        = 10250
      description = "Kubelet metrics between cluster nodes for the HPA"
    }
    postgresql = {
      source      = "app"
      destination = "database"
      protocol    = "tcp"
      port        = 5432
      description = "Application nodes connecting to private PostgreSQL"
    }
  }
}

# Keep accidental launches that use only the VPC default group isolated.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.project.id
  tags   = { Name = "${var.resource_prefix}-default-deny" }
}

resource "aws_security_group" "workload" {
  for_each = local.security_groups

  name        = "${var.resource_prefix}-${each.key}-sg"
  description = each.value
  vpc_id      = aws_vpc.project.id

  tags = { Name = "${var.resource_prefix}-${each.key}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "public_web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.workload["ingress"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Public ${upper(each.key)} to the ingress controller"

  tags = { Name = "${var.resource_prefix}-public-${each.key}" }
}

resource "aws_vpc_security_group_ingress_rule" "private" {
  for_each = local.private_flows

  security_group_id            = aws_security_group.workload[each.value.destination].id
  referenced_security_group_id = aws_security_group.workload[each.value.source].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.description

  tags = { Name = "${var.resource_prefix}-${each.key}-in" }
}

resource "aws_vpc_security_group_egress_rule" "private" {
  for_each = local.private_flows

  security_group_id            = aws_security_group.workload[each.value.source].id
  referenced_security_group_id = aws_security_group.workload[each.value.destination].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.description

  tags = { Name = "${var.resource_prefix}-${each.key}-out" }
}
