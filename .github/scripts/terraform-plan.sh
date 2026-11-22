#!/usr/bin/env bash
set -euo pipefail

# Exercise the deployed module with its locked AWS provider and a fresh local state.
repo=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
cp "$repo"/infra/*.tf "$repo/infra/.terraform.lock.hcl" "$scratch/"
cp "$repo/.github/scripts/check-network-plan.jq" "$scratch/"
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
terraform plan -input=false -refresh=false -out=network.tfplan
terraform show -json network.tfplan | jq -er -f check-network-plan.jq
