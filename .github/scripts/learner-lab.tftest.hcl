# Only the Academy-provided profile and IDs assigned during apply are simulated.
# Planning never invokes the real bucket helper or contacts a lab account.
run "learner_lab" {
  command = plan

  variables {
    learner_lab = { bucket_name = "dv-ayan-kassen-1951-bootstrap-ci" }
    ami_id      = "ami-0123456789abcdef0"
  }

  override_data {
    target          = data.aws_iam_instance_profile.learner[0]
    override_during = plan
    values = {
      arn      = "arn:aws:iam::123456789012:instance-profile/LabInstanceProfile"
      name     = "LabInstanceProfile"
      role_arn = "arn:aws:iam::123456789012:role/LabRole"
    }
  }
  override_resource {
    target          = aws_vpc.project
    override_during = plan
    values          = { id = "vpc-0123456789abcdef0" }
  }
  override_resource {
    target          = aws_vpc_endpoint.bootstrap
    override_during = plan
    values          = { id = "vpce-0123456789abcdef0" }
  }
  override_resource {
    target          = aws_ecr_repository.app
    override_during = plan
    values          = { arn = "arn:aws:ecr:us-east-1:123456789012:repository/dv-ayan-kassen-1951-scholarship-applications" }
  }
  override_resource {
    target          = aws_subnet.project["private"]
    override_during = plan
    values          = { id = "subnet-0123456789abcdef0" }
  }
  override_resource {
    target          = aws_security_group.workload["registry"]
    override_during = plan
    values          = { id = "sg-0123456789abcdef0" }
  }
  override_resource {
    target          = aws_security_group.workload["app"]
    override_during = plan
    values          = { id = "sg-0123456789abcdef1" }
  }

  assert {
    condition = (
      length(aws_iam_role.node) == 0 && length(aws_iam_role_policy.bootstrap) == 0 &&
      length(aws_iam_instance_profile.node) == 0 && length(aws_kms_key.bootstrap) == 0 &&
      length(aws_s3_bucket.bootstrap) == 0 && length(terraform_data.bootstrap_bucket) == 1 &&
      terraform_data.bootstrap_bucket[0].input.bucket == var.learner_lab.bucket_name &&
      terraform_data.bootstrap_bucket[0].input.owner == "123456789012"
    )
    error_message = "Learner Lab must use its existing IAM identity and dedicated bucket helper."
  }

  assert {
    condition = alltrue([
      for role, node in { server = aws_instance.server, agent = aws_instance.agent } :
      node.iam_instance_profile == "LabInstanceProfile" && node.instance_type == "t3.small" &&
      node.ami == var.ami_id && node.private_ip == (role == "server" ? "10.56.1.10" : "10.56.2.10") &&
      node.associate_public_ip_address == (role == "server") && node.user_data_replace_on_change &&
      node.user_data == local.lab_node_user_data[role] &&
      strcontains(node.user_data, "role='${role}'") && strcontains(node.user_data, "bucket='${var.learner_lab.bucket_name}'") &&
      strcontains(node.user_data, "/usr/local/sbin/css4003-observe ${role} || true") &&
      length(trim(base64encode(node.user_data), "=")) <= ceil(16384 * 4 / 3)
    ])
    error_message = "Both EC2 nodes must use the lab profile, pinned bootstrap and bounded, role-specific user data."
  }

  assert {
    condition = (
      aws_s3_bucket_server_side_encryption_configuration.bootstrap.bucket == var.learner_lab.bucket_name &&
      one(aws_s3_bucket_server_side_encryption_configuration.bootstrap.rule).bucket_key_enabled &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.bootstrap.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      aws_s3_bucket_public_access_block.bootstrap.block_public_acls && aws_s3_bucket_public_access_block.bootstrap.ignore_public_acls &&
      aws_s3_bucket_public_access_block.bootstrap.block_public_policy && aws_s3_bucket_public_access_block.bootstrap.restrict_public_buckets
    )
    error_message = "The lab bucket must use the AWS-managed S3 KMS key with public access fully blocked."
  }

  assert {
    condition = (
      toset(keys(aws_s3_object.release)) == toset(["k3s", "k3s-airgap-images-amd64.tar.zst", "sha256sum-amd64.txt"]) &&
      toset(local.release_object_arns) == toset([for key, obj in aws_s3_object.release : "arn:aws:s3:::${var.learner_lab.bucket_name}/${obj.key}"]) &&
      alltrue([for key, obj in aws_s3_object.release :
        obj.bucket == var.learner_lab.bucket_name && obj.key == "releases/${local.k3s_version}/${key}" && can(regex("^[0-9a-f]{64}$", obj.source_hash))
      ]) &&
      local.token_object_arn == "arn:aws:s3:::${var.learner_lab.bucket_name}/cluster/agent-token" &&
      aws_vpc_endpoint.bootstrap.vpc_endpoint_type == "Gateway" &&
      aws_vpc_endpoint.bootstrap.service_name == "com.amazonaws.us-east-1.s3" &&
      length(jsondecode(aws_vpc_endpoint.bootstrap.policy).Statement) == 4 &&
      alltrue([for stmt in jsondecode(aws_vpc_endpoint.bootstrap.policy).Statement :
        stmt.Effect == "Allow" && stmt.Principal == "*" &&
        stmt.Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::123456789012:role/LabRole" &&
        stmt.Condition.StringEquals["aws:Ec2InstanceSourceVpc"] == aws_vpc.project.id &&
        (stmt.Action == "s3:GetObject" ? (
          toset(stmt.Resource) == toset(concat(local.release_object_arns, [local.token_object_arn])) &&
          toset(stmt.Condition.IpAddress["aws:VpcSourceIp"]) == toset(["10.56.1.10", "10.56.2.10"]) &&
          toset(stmt.Condition.IpAddress["aws:Ec2InstanceSourcePrivateIPv4"]) == toset(["10.56.1.10", "10.56.2.10"])
          ) : (
          stmt.Action == "s3:PutObject" && stmt.Resource == local.token_object_arn &&
          stmt.Condition.IpAddress["aws:VpcSourceIp"] == "10.56.1.10" &&
          stmt.Condition.IpAddress["aws:Ec2InstanceSourcePrivateIPv4"] == "10.56.1.10"
        )) if contains(["ReadBootstrapFromNodes", "PublishAgentTokenFromServer"], stmt.Sid)
        ]) && toset([for s in jsondecode(aws_vpc_endpoint.bootstrap.policy).Statement : s.Sid]) == toset([
        "ReadBootstrapFromNodes", "PublishAgentTokenFromServer", "ReadECRLayersFromNodes", "DatabaseAgentBackups"
      ])
    )
    error_message = "Both nodes may read the pinned release and token. Only the server may publish the token via the gateway."
  }

  assert {
    condition = (
      length(aws_s3_bucket.backups) == 0 && length(aws_kms_key.backups) == 0 &&
      terraform_data.backup_bucket[0].input.bucket == "dv-ayan-kassen-1951-backups-ci" &&
      output.backup_bucket_name == "dv-ayan-kassen-1951-backups-ci" &&
      aws_s3_bucket_lifecycle_configuration.backups.bucket == output.backup_bucket_name &&
      one(aws_s3_bucket_lifecycle_configuration.backups.rule).status == "Enabled" &&
      one(one(aws_s3_bucket_lifecycle_configuration.backups.rule).filter).prefix == "postgresql/" &&
      one(one(aws_s3_bucket_lifecycle_configuration.backups.rule).expiration).days == 7 &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.backups.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      aws_s3_bucket_public_access_block.backups.block_public_acls && aws_s3_bucket_public_access_block.backups.ignore_public_acls &&
      aws_s3_bucket_public_access_block.backups.block_public_policy && aws_s3_bucket_public_access_block.backups.restrict_public_buckets &&
      anytrue([for s in jsondecode(aws_vpc_endpoint.bootstrap.policy).Statement : jsonencode(s) == jsonencode({
        Sid       = "DatabaseAgentBackups"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource  = "arn:aws:s3:::dv-ayan-kassen-1951-backups-ci/postgresql/campus-*.dump"
        Condition = {
          ArnEquals    = { "aws:PrincipalArn" = "arn:aws:iam::123456789012:role/LabRole" }
          StringEquals = { "aws:Ec2InstanceSourceVpc" = aws_vpc.project.id }
          IpAddress    = { "aws:VpcSourceIp" = "10.56.2.10", "aws:Ec2InstanceSourcePrivateIPv4" = "10.56.2.10" }
        }
      })])
    )
    error_message = "The private encrypted backup bucket must expire archives after seven days and restrict node access to the database agent."
  }

  assert {
    condition = (
      aws_ecr_repository.app.name == "dv-ayan-kassen-1951-scholarship-applications" &&
      aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE" &&
      one(aws_ecr_repository.app.image_scanning_configuration).scan_on_push &&
      one(aws_ecr_repository.app.encryption_configuration).encryption_type == "KMS" &&
      toset(keys(aws_vpc_endpoint.ecr)) == toset(["api", "dkr"]) &&
      alltrue([for service, ep in aws_vpc_endpoint.ecr :
        ep.service_name == "com.amazonaws.us-east-1.ecr.${service}" && ep.vpc_endpoint_type == "Interface" &&
        ep.private_dns_enabled && ep.subnet_ids == toset([aws_subnet.project["private"].id]) &&
        ep.security_group_ids == toset([aws_security_group.workload["registry"].id]) &&
        length(jsondecode(ep.policy).Statement) == 2 &&
        alltrue([for s in jsondecode(ep.policy).Statement :
          s.Effect == "Allow" && s.Principal == "*" && (s.Sid == "RegistryLogin" ?
            (s.Resource == "*" && toset(s.Action) == toset(["ecr:GetAuthorizationToken"])) :
            (s.Sid == "ReadAppImage" && s.Resource == aws_ecr_repository.app.arn &&
          toset(s.Action) == toset(["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"])))
        ]) && toset([for s in jsondecode(ep.policy).Statement : s.Sid]) == toset(["RegistryLogin", "ReadAppImage"])
      ])
    )
    error_message = "Both private ECR endpoints must serve only login and pulls from the immutable, scanned application repository."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.private["ecr"].security_group_id == aws_security_group.workload["registry"].id &&
      aws_vpc_security_group_ingress_rule.private["ecr"].referenced_security_group_id == aws_security_group.workload["app"].id &&
      aws_vpc_security_group_egress_rule.private["ecr"].security_group_id == aws_security_group.workload["app"].id &&
      aws_vpc_security_group_egress_rule.private["ecr"].referenced_security_group_id == aws_security_group.workload["registry"].id &&
      alltrue([for rule in [aws_vpc_security_group_ingress_rule.private["ecr"], aws_vpc_security_group_egress_rule.private["ecr"]] :
        rule.ip_protocol == "tcp" && rule.from_port == 443 && rule.to_port == 443
      ]) &&
      anytrue([for s in jsondecode(aws_vpc_endpoint.bootstrap.policy).Statement :
        jsonencode(s) == jsonencode({
          Sid       = "ReadECRLayersFromNodes"
          Effect    = "Allow"
          Principal = "*"
          Action    = "s3:GetObject"
          Resource  = "arn:aws:s3:::prod-us-east-1-starport-layer-bucket/*"
          Condition = { IpAddress = { "aws:VpcSourceIp" = ["10.56.1.10", "10.56.2.10"] } }
        })
      ])
    )
    error_message = "Allow HTTPS from the node group to ECR and presigned layer downloads only from the two node addresses."
  }

  assert {
    condition = (
      length(jsondecode(aws_s3_bucket_policy.bootstrap.policy).Statement) == 2 &&
      alltrue([for s in jsondecode(aws_s3_bucket_policy.bootstrap.policy).Statement :
        s.Effect == "Deny" && s.Principal == "*" && s.Action == "s3:*" &&
        toset(s.Resource) == toset(["arn:aws:s3:::${var.learner_lab.bucket_name}", "arn:aws:s3:::${var.learner_lab.bucket_name}/*"])
      ]) &&
      anytrue([for s in jsondecode(aws_s3_bucket_policy.bootstrap.policy).Statement :
        try(s.Condition.Bool["aws:SecureTransport"] == "false", false)
      ]) &&
      anytrue([for s in jsondecode(aws_s3_bucket_policy.bootstrap.policy).Statement :
        try(s.Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::123456789012:role/LabRole" &&
        s.Condition.Null["ec2:SourceInstanceARN"] == "false" && s.Condition.StringNotEquals["aws:SourceVpce"] == aws_vpc_endpoint.bootstrap.id, false)
      ])
    )
    error_message = "The bucket must reject plaintext requests and node credentials used outside its bootstrap endpoint."
  }
}
