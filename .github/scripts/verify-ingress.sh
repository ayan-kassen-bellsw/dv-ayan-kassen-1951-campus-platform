#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && ( $1 == main || $1 == prod ) ]] || { echo "Usage: $0 main|prod" >&2; exit 2; }
target=$1
: "${SOURCE_SHA:?Set the approved image SHA}" "${K3S_APP_URL:?Set the public Ingress origin}"
[[ $SOURCE_SHA =~ ^[0-9a-f]{40}$ ]]
origin=${K3S_APP_URL%/}
[[ $origin =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]{1,5})?$ ]]
version=
declare -A hosts=()
request=(curl --proto '=http,https' --fail --silent --connect-timeout 3 --max-time 5 --max-filesize 65536)
if [[ $target == prod ]]; then
  version=${RELEASE_VERSION:?Set the approved SemVer tag}
  request+=(--header 'Host: prod.scholarships.test')
fi
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  if [[ $target == main ]]; then
    ref=$(git ls-remote --exit-code origin refs/heads/main)
    if [[ $ref != "$SOURCE_SHA"$'\trefs/heads/main' ]]; then
      echo "A newer main commit has superseded verification of $SOURCE_SHA."
      exit 0
    fi
  fi
  # Consecutive /info requests also sample both backends on a round-robin Ingress.
  if host=$("${request[@]}" "$origin/info" | jq -er --arg sha "$SOURCE_SHA" --arg version "$version" \
      'select(.git_sha == $sha and ($version == "" or .version == $version)) | .hostname |
       select(type == "string" and test("^[a-z0-9][a-z0-9.-]{0,252}$")) |
       select($version == "" or startswith("dv-ayan-kassen-1951-prod-"))'); then
    hosts[$host]=1
    if (( ${#hosts[@]} >= 2 )) && "${request[@]}" "$origin/readyz" |
      jq -e '.ready == true and .checks.db == true and .checks.storage == true' >/dev/null; then
      echo "$target Ingress verified ${version:+$version at }$SOURCE_SHA on replicas ${!hosts[*]} with database and attachment storage ready."
      exit 0
    fi
  else
    hosts=()
  fi
  sleep 6
done
echo "Timed out waiting for $SOURCE_SHA on two ready k3s replicas. Check the ECR marker and the server deploy service journal." >&2
exit 1
