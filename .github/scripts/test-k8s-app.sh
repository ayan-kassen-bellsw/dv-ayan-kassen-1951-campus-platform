#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $(kubectl config current-context) == "k3d-${K3D_TEST_CLUSTER:?Run with test-k3s.sh}" ]]
: "${K3D_INGRESS_URL:?Test cluster must expose Traefik on loopback}"
ns=dv-ayan-kassen-1951
app=$ns-app
k=(kubectl --namespace "$ns")
work=$(mktemp -d)
monitor=
cleanup() {
  touch "$work/finished"
  if [[ -n "$monitor" ]]; then wait "$monitor" || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

export APP_MODE=local APP_OWNER='Scholarship CI' APP_VERSION=local-1
export APP_IMAGE=${K3D_TEST_APP_IMAGE:-campus-app:dev}
GIT_SHA=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$APP_IMAGE")
export GIT_SHA
k3d image import "$APP_IMAGE" --cluster "$K3D_TEST_CLUSTER"
bash ops/deploy-app.sh apply

curl -fsS --retry 30 --retry-all-errors --retry-delay 2 --retry-max-time 90 "$K3D_INGRESS_URL/readyz" |
  jq -e '.ready and .checks.db and .checks.storage'
curl -fsS "$K3D_INGRESS_URL/info" |
  jq -e --arg sha "$GIT_SHA" '.git_sha == $sha and .storage_backend == "database" and .db_engine == "postgresql"'
sample="Aa1$(openssl rand -hex 7)"
jq -nc --arg sample "${sample:0:16}" '{password:$sample}' |
  curl -fsS --json @- "$K3D_INGRESS_URL/api/admin/check-password" |
  jq -e '.ok and .min_length == 16 and .require_symbol == false'
[[ $("${k[@]}" get deployment "$app" -o jsonpath='{.status.readyReplicas}') -ge 2 ]]
"${k[@]}" get hpa "$app" -o json | jq -e '.spec.minReplicas == 2 and .spec.metrics[0].resource.target.averageUtilization == 70'

item_id=$(curl -fsS --json '{"title":"Ingress scholarship","description":"Two-replica test"}' \
  "$K3D_INGRESS_URL/api/items" | jq -er '.id | numbers')
item_url="$K3D_INGRESS_URL/api/items/$item_id"
openssl rand 1024 > "$work/attachment"
curl -fsS -F "file=@$work/attachment;type=application/octet-stream" "$item_url/attachment" |
  jq -e --argjson id "$item_id" '.id == $id and .attachment_name == "attachment"'
checksum=$(sha256sum "$work/attachment" | cut -d ' ' -f 1)
pods=$("${k[@]}" get pods -l app.kubernetes.io/name=scholarship-applications -o name)
for pod in $pods; do
  "${k[@]}" exec "$pod" -- python -c '
import hashlib, sys, urllib.request
with urllib.request.urlopen("http://127.0.0.1:8000/api/items/" + sys.argv[1] + "/attachment", timeout=5) as response:
    assert hashlib.sha256(response.read()).hexdigest() == sys.argv[2]
' "$item_id" "$checksum"
done

# Check the stored application continuously through Traefik throughout both revision changes.
(
  while [[ ! -f "$work/finished" ]]; do
    curl --fail --silent --show-error --max-time 4 "$item_url" | jq -e '.title == "Ingress scholarship"' > /dev/null
    echo ok
    sleep 0.25
  done
) > "$work/requests" &
monitor=$!
APP_VERSION=local-2 bash ops/deploy-app.sh apply
expect_version() {
  local version=$1
  for ((attempt=0; attempt<30; attempt++)); do
    if curl -fsS "$K3D_INGRESS_URL/info" | jq -e --arg version "$version" '.version == $version' > /dev/null; then return; fi
    sleep 1
  done
  return 1
}
expect_version local-2
"${k[@]}" rollout undo "deployment/$app"
"${k[@]}" rollout status "deployment/$app" --timeout=3m
expect_version local-1
touch "$work/finished"
wait "$monitor"
monitor=
test -s "$work/requests"
curl -fsS "$item_url/attachment" > "$work/download"
cmp "$work/attachment" "$work/download"
echo "Ingress -> PostgreSQL, attachments on both replicas, HPA target, update and rollback passed. $(wc -l < "$work/requests") sampled requests succeeded."
