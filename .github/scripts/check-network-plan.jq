def require($condition; $message): if $condition then . else error($message) end;
def resources($type): [.planned_values.root_module.resources[] | select(.type == $type)];

resources("aws_subnet") as $subnets
| resources("aws_vpc_security_group_ingress_rule") as $ingress
| [$ingress[] | select(.values.cidr_ipv4 == "0.0.0.0/0" or .values.cidr_ipv6 == "::/0")] as $public_ingress
| .configuration.root_module.resources as $config
| [$config[] | select(.type == "aws_route" and .expressions.gateway_id)] as $gateway_routes
| require(any(resources("aws_vpc")[]; .values.cidr_block == "10.56.0.0/16"); "Missing project VPC")
| require(any($subnets[]; .index == "public" and .values.cidr_block == "10.56.1.0/24"); "Missing public subnet")
| require(any($subnets[];
    .index == "private" and .values.cidr_block == "10.56.2.0/24" and .values.map_public_ip_on_launch == false
  ); "Missing private subnet or automatic public IP assignment enabled")
| require(any(resources("aws_route_table_association")[]; .index == "private")
    and any($config[]; .address == "aws_route_table_association.project"
      and (.expressions.subnet_id.references | index("each.key") != null)
      and (.expressions.route_table_id.references | index("each.key") != null)
    ); "Each subnet must use its own route table")
| require(any(resources("aws_route")[];
    .name == "public_internet" and .values.destination_cidr_block == "0.0.0.0/0"
  ); "Missing public default route")
| require(any($gateway_routes[]; .name == "public_internet") and all($gateway_routes[];
    any(.expressions.route_table_id.references[]; startswith("aws_route_table.project[\"public\"]"))
  ); "An Internet gateway route targets a route table other than the public one")
| require(([$public_ingress[] | .values | [.ip_protocol, .from_port, .to_port]] | unique)
    == [["tcp", 80, 80], ["tcp", 443, 443]]; "Public ingress must expose only TCP 80 and 443")
| require(all($public_ingress[]; .name == "public_web") and any($config[];
    .address == "aws_vpc_security_group_ingress_rule.public_web" and
    (.expressions.security_group_id.references | index("aws_security_group.workload[\"ingress\"]") != null)
  ); "Only the ingress security group can accept public traffic")
| require(any($ingress[]; .index == "postgresql" and .values.ip_protocol == "tcp" and .values.from_port == 5432)
    and all($ingress[] | .values | select(.ip_protocol == "-1" or (.from_port <= 5432 and .to_port >= 5432));
      .cidr_ipv4 == null and .cidr_ipv6 == null and .prefix_list_id == null
    ); "PostgreSQL must accept connections only from a security group")
| "Network plan passed VPC, subnet, route and ingress checks."
