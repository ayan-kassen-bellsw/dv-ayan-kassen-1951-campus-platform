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

output "node_instance_ids" {
  description = "EC2 IDs for the k3s server and agent."
  value       = { server = aws_instance.server.id, agent = aws_instance.agent.id }
}

output "node_private_ips" {
  description = "Private node addresses used for cluster traffic."
  value       = { server = aws_instance.server.private_ip, agent = aws_instance.agent.private_ip }
}

output "server_public_ip" {
  description = "Public IPv4 address of the server running the ingress controller."
  value       = aws_instance.server.public_ip
}

output "bootstrap_bucket" {
  description = "Name of the private bucket for the pinned k3s release and its runtime agent token."
  value       = aws_s3_bucket.bootstrap.id
}
