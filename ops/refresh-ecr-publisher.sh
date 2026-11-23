#!/usr/bin/env bash
set +x
set -euo pipefail

github_repo=ayan-kassen-bellsw/dv-ayan-kassen-1951-campus-platform
repository=dv-ayan-kassen-1951-scholarship-applications
region=us-east-1
reference=${1:-v0.1.0}
if (( $# > 1 )) || [[ $reference != v0.1.0 && ! $reference =~ ^[a-f0-9]{40}$ ]]; then
  echo "Usage: $0 [published-full-git-SHA] (defaults to v0.1.0)" >&2
  exit 2
fi

registry=$(gh variable get ECR_REGISTRY --repo "$github_repo")
uri=$(aws ecr describe-repositories --region "$region" --repository-names "$repository" \
  --query 'repositories[0].repositoryUri' --output text)
if [[ ! $registry =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com$ || $uri != "$registry/$repository" ]]; then
  echo 'ECR_REGISTRY in GitHub does not match the repository of the active Learner Lab session.' >&2
  exit 1
fi

password=$(aws ecr get-login-password --region "$region")
[[ -n $password ]] || { echo 'AWS returned an empty ECR password.' >&2; exit 1; }
accept='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'
# Pass the Basic header to curl over stdin to keep the password out of process arguments.
status=$({
  printf 'Authorization: Basic '
  printf 'AWS:%s' "$password" | base64 | tr -d '\r\n'
  printf '\n'
} | curl --proto '=https' --silent --show-error --connect-timeout 10 --max-time 60 \
  --header @- --header "Accept: $accept" --output /dev/null --write-out '%{http_code}' \
  "https://$registry/v2/$repository/manifests/$reference")
[[ $status == 200 ]] || { echo "The new ECR password could not read $reference (HTTP $status)." >&2; exit 1; }
printf '%s' "$password" | gh secret set ECR_PUSH_PASSWORD --repo "$github_repo" --env ecr-publish
echo "Verified $reference and refreshed ECR_PUSH_PASSWORD in the ecr-publish GitHub environment."
