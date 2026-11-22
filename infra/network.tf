locals {
  subnet_cidrs = {
    public  = cidrsubnet(var.vpc_cidr, 8, 1)
    private = cidrsubnet(var.vpc_cidr, 8, 2)
  }
}

resource "aws_vpc" "project" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.resource_prefix}-vpc" }
}

resource "aws_subnet" "project" {
  for_each = local.subnet_cidrs

  vpc_id                  = aws_vpc.project.id
  availability_zone       = "${var.aws_region}a"
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${var.resource_prefix}-${each.key}-subnet" }
}

resource "aws_internet_gateway" "public" {
  vpc_id = aws_vpc.project.id
  tags   = { Name = "${var.resource_prefix}-igw" }
}

resource "aws_route_table" "project" {
  for_each = local.subnet_cidrs

  vpc_id = aws_vpc.project.id
  tags   = { Name = "${var.resource_prefix}-${each.key}-routes" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.project["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.public.id
}

resource "aws_route_table_association" "project" {
  for_each = local.subnet_cidrs

  subnet_id      = aws_subnet.project[each.key].id
  route_table_id = aws_route_table.project[each.key].id
}
