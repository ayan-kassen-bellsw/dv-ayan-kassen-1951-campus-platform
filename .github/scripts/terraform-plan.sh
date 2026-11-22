#!/usr/bin/env bash
set -euo pipefail
umask 077

# Exercise the deployed module with its locked AWS provider and a fresh local state.
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cp "$repo"/infra/*.tf "$repo/infra/.terraform.lock.hcl" "$scratch/"
cp -R "$repo/infra/bootstrap" "$scratch/"
cp "$repo"/.github/scripts/check-{network,k3s}-plan.jq "$scratch/"
cd "$scratch"
terraform init -input=false -backend=false -lockfile=readonly
terraform validate

# Only the disposable copy gets offline settings. An AWS lookup will fail on loopback.
cat > override.tf <<'HCL'
provider "aws" {
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  max_retries                 = 0
}
HCL
export AWS_ACCESS_KEY_ID=offline AWS_SECRET_ACCESS_KEY=offline
export AWS_EC2_METADATA_DISABLED=true AWS_ENDPOINT_URL=http://127.0.0.1:1
# A fixed AMI exercises the two EC2 resources without resolving a public SSM parameter.
export TF_VAR_ami_id=ami-0123456789abcdef0
terraform plan -input=false -refresh=false -out=cluster.tfplan
terraform show -json cluster.tfplan > plan.json
jq -er -f check-network-plan.jq plan.json
jq -er -f check-k3s-plan.jq plan.json

# Give the generated bucket a known name *after* checking the untouched resource plan,
# so Terraform can render the exact user data expressions passed to both instances.
cat >> override.tf <<'HCL'
resource "aws_s3_bucket" "bootstrap" {
  bucket_prefix = null
  bucket        = "ci-bootstrap-fixture"
}
HCL
terraform console -plan -no-color <<<'jsonencode(local.node_user_data)' | jq -er 'fromjson' > rendered.json
for role in server agent; do
  jq -bje --arg role "$role" '.[$role]' rendered.json > "$role.sh"
  bash -n "$role.sh"
done
bash "$repo/.github/scripts/test-k3s-bootstrap.sh" "$scratch/server.sh" "$scratch/agent.sh"
