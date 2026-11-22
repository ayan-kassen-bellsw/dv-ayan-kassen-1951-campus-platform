output "vpc_id" {
  description = "ID of the scholarship platform VPC."
  value       = aws_vpc.project.id
}

output "vpc_cidr" {
  description = "IPv4 network assigned to the VPC."
  value       = aws_vpc.project.cidr_block
}

output "subnet_ids" {
  description = "Subnet IDs keyed by public and private."
  value       = { for name, subnet in aws_subnet.project : name => subnet.id }
}

output "subnet_cidrs" {
  description = "IPv4 ranges keyed by public and private."
  value       = local.subnet_cidrs
}

output "route_table_ids" {
  description = "Route table IDs keyed by public and private."
  value       = { for name, table in aws_route_table.project : name => table.id }
}

output "security_group_ids" {
  description = "Security group IDs keyed by ingress, app and database."
  value       = { for name, group in aws_security_group.workload : name => group.id }
}
