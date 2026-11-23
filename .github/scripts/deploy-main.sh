#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && ( $1 == mark || $1 == verify ) ]] || { echo "Usage: $0 mark|verify" >&2; exit 2; }
: "${SOURCE_SHA:?Set SOURCE_SHA to the commit tested on main}"
[[ $SOURCE_SHA =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source SHA' >&2; exit 2; }

if [[ $1 == verify ]]; then
  exec bash "$(dirname "$0")/verify-ingress.sh" main
fi
ref=$(git ls-remote --exit-code origin refs/heads/main)
if [[ $ref != "$SOURCE_SHA"$'\trefs/heads/main' ]]; then
  echo "A newer main commit has superseded $SOURCE_SHA."
  exit 0
fi
: "${K3S_APP_URL:?Set the public HTTP(S) Ingress origin}"
origin=${K3S_APP_URL%/}
[[ $origin =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]{1,5})?$ ]] ||
  { echo 'Set K3S_APP_URL to the public HTTP(S) Ingress origin' >&2; exit 2; }

: "${ECR_REGISTRY:?Set the private registry hostname}" "${CI_RUN_NUMBER:?Set the upstream CI run number}"
[[ $CI_RUN_NUMBER =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid CI run number' >&2; exit 2; }
bash "$(dirname "$0")/publish-ecr.sh" "$ECR_REGISTRY/dv-ayan-kassen-1951-scholarship-applications" \
  "$SOURCE_SHA" "deploy-main-$CI_RUN_NUMBER-$SOURCE_SHA"
echo 'marked=true' >> "${GITHUB_OUTPUT:?Set the step output path}"
