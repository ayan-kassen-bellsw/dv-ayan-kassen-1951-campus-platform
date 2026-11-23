def require($ok; $message): if $ok then . else error($message) end;
def references($resource; $attribute): $resource.expressions[$attribute].references // [];
def linked($resource; $attribute; $target): references($resource; $attribute) | index($target) != null;

def check_node($resources; $config; $role; $subnet; $ip; $public; $groups):
  ("aws_instance." + $role) as $address
  | $resources[$address].values as $vm
  | $config[$address] as $spec
  | require(linked($spec; "subnet_id"; "aws_subnet.project[\"\($subnet)\"].id")
      and $vm.private_ip == $ip and $vm.associate_public_ip_address == $public;
      "\($role) must use its assigned subnet and IP settings")
  | require(([references($spec; "vpc_security_group_ids")[] | select(endswith(".id"))] | sort)
      == ([$groups[] | "aws_security_group.workload[\"\(.)\"].id"] | sort);
      "\($role) must use only its designated security groups")
  | require($vm.iam_instance_profile == $resources["aws_iam_instance_profile.node[\"\($role)\"]"].values.name
      and $vm.iam_instance_profile == ("dv-ayan-kassen-1951-k3s-" + $role)
      and linked($spec; "user_data"; "local.node_user_data.\($role)")
      and $vm.user_data_replace_on_change == true;
      "\($role) must use its own instance profile and bootstrap script")
  | require(any($vm.metadata_options[]; .http_tokens == "required")
      and any($vm.root_block_device[]; .encrypted == true);
      "\($role) must require IMDSv2 and encrypt its root volume");

INDEX(.planned_values.root_module.resources[]; .address) as $resources
| INDEX(.configuration.root_module.resources[]; .address) as $config
| require(([$resources[] | select(.type == "aws_instance") | .address] | sort)
    == ["aws_instance.agent", "aws_instance.server"]; "Plan must contain exactly one server and one agent")
| check_node($resources; $config; "server"; "public"; "10.56.1.10"; true; ["ingress", "app"])
| check_node($resources; $config; "agent"; "private"; "10.56.2.10"; false; ["app"])
| require(([$resources[] | select(.type == "aws_iam_role") | .index] | sort) == ["agent", "server"]
    and ([$resources[] | select(.type == "aws_iam_role_policy") | .index] | sort) == ["agent", "server"]
    and $resources["aws_kms_key.bootstrap[0]"].values.enable_key_rotation == true
    and $resources["aws_s3_bucket.bootstrap[0]"].values.bucket_prefix == "dv-ayan-kassen-1951-bootstrap-"
    and all($resources[]; .type != "terraform_data" or .name != "bootstrap_bucket");
    "The standard account must create its own roles, bucket and rotating KMS key")
| $resources["aws_vpc_endpoint.bootstrap"].values as $s3
| $resources["aws_s3_bucket.backups[0]"].values as $backup
| require($backup.bucket_prefix == "dv-ayan-kassen-1951-backups-" and $backup.force_destroy == false
    and $resources["aws_kms_key.backups[0]"].values.enable_key_rotation == true
    and any($resources["aws_s3_bucket_lifecycle_configuration.backups"].values.rule[];
      .status == "Enabled" and .filter[0].prefix == "postgresql/" and .expiration[0].days == 7)
    and linked($config["aws_iam_role_policy.bootstrap"]; "policy"; "local.backup_permissions");
    "Standard accounts must protect backup archives and expire them after seven days")
| $resources["aws_ecr_repository.app"].values as $ecr
| require($ecr.name == "dv-ayan-kassen-1951-scholarship-applications" and $ecr.image_tag_mutability == "IMMUTABLE"
    and any($ecr.image_scanning_configuration[]; .scan_on_push == true)
    and any($ecr.encryption_configuration[]; .encryption_type == "KMS")
    and linked($config["aws_iam_role_policy.bootstrap"]; "policy"; "local.ecr_pull_permissions")
    and ([$resources[] | select(.type == "aws_vpc_endpoint" and .name == "ecr") | .index] | sort) == ["api", "dkr"];
    "Standard accounts must have a scanned private ECR repository, read permissions for the nodes and both ECR endpoints")
| require($s3.vpc_endpoint_type == "Gateway" and $s3.service_name == "com.amazonaws.us-east-1.s3"
    and references($config["aws_vpc_endpoint.bootstrap"]; "route_table_ids") == ["aws_route_table.project"];
    "The S3 gateway endpoint must serve both project route tables")
| $resources["aws_vpc_security_group_egress_rule.bootstrap_s3"].values as $https
| $config["aws_vpc_security_group_egress_rule.bootstrap_s3"] as $rule
| require($https.ip_protocol == "tcp" and $https.from_port == 443 and $https.to_port == 443
    and linked($rule; "security_group_id"; "aws_security_group.workload[\"app\"].id")
    and linked($rule; "prefix_list_id"; "aws_vpc_endpoint.bootstrap.prefix_list_id");
    "Bootstrap HTTPS must target the S3 prefix list from the node security group")
| require(all($resources[] | select(.type == "aws_vpc_security_group_egress_rule");
    .values.cidr_ipv4 == null and .values.cidr_ipv6 == null); "Node egress must use security groups or the S3 prefix list")
| "k3s plan passed instance, bootstrap, IAM, network and storage access checks."
