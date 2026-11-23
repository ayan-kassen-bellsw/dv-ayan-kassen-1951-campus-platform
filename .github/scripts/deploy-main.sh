#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && ( $1 == mark || $1 == verify ) ]] || { echo "Usage: $0 mark|verify" >&2; exit 2; }
: "${SOURCE_SHA:?Set SOURCE_SHA to the commit tested on main}"
[[ $SOURCE_SHA =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source SHA' >&2; exit 2; }

current_main() {
  local ref
  ref=$(git ls-remote --exit-code origin refs/heads/main) || { echo 'Could not read main from GitHub' >&2; exit 1; }
  [[ $ref == "$SOURCE_SHA"$'\trefs/heads/main' ]]
}

if ! current_main; then
  echo "A newer main commit has superseded $SOURCE_SHA."
  exit 0
fi
: "${K3S_APP_URL:?Set the public HTTP(S) Ingress origin}"
origin=${K3S_APP_URL%/}
[[ $origin =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]{1,5})?$ ]] ||
  { echo 'Set K3S_APP_URL to the public HTTP(S) Ingress origin' >&2; exit 2; }

if [[ $1 == mark ]]; then
  : "${ECR_REGISTRY:?Set the private registry hostname}" "${CI_RUN_NUMBER:?Set the upstream CI run number}"
  [[ $CI_RUN_NUMBER =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid CI run number' >&2; exit 2; }
  bash "$(dirname "$0")/publish-ecr.sh" "$ECR_REGISTRY/dv-ayan-kassen-1951-scholarship-applications" \
    "$SOURCE_SHA" "deploy-main-$CI_RUN_NUMBER-$SOURCE_SHA"
  echo 'marked=true' >> "${GITHUB_OUTPUT:?Set the step output path}"
  exit 0
fi

# A healthy old replica may answer during a rolling update. Observe the new SHA
# on two distinct ready application replicas before reporting a successful deploy.
declare -A hosts=()
request=(curl --proto '=http,https' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 65536)
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  if ! current_main; then
    echo "A newer main commit has superseded verification of $SOURCE_SHA."
    exit 0
  fi
  # Consecutive /info requests also sample both backends on a round-robin Ingress.
  if host=$("${request[@]}" "$origin/info" | jq -er --arg sha "$SOURCE_SHA" \
      'select(.git_sha == $sha) | .hostname | select(type == "string" and test("^[a-z0-9][a-z0-9.-]{0,252}$"))'); then
    hosts[$host]=1
    if (( ${#hosts[@]} >= 2 )) && "${request[@]}" "$origin/readyz" |
      jq -e '.ready == true and .checks.db == true and .checks.storage == true' >/dev/null; then
      echo "Ingress verified $SOURCE_SHA on replicas ${!hosts[*]} with database and attachment storage ready."
      exit 0
    fi
  else
    hosts=()
  fi
  sleep 6
done
echo "Timed out waiting for $SOURCE_SHA on two ready k3s replicas. Check the ECR marker and the server deploy service journal." >&2
exit 1
