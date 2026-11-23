#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $(kubectl config current-context) == "k3d-${K3D_TEST_CLUSTER:?Run with test-k3s.sh}" ]]
ns=dv-ayan-kassen-1951
pod=$ns-postgres-0
export BACKUP_TEST_WORKER
BACKUP_TEST_WORKER=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
[[ "$BACKUP_TEST_WORKER" == "k3d-$K3D_TEST_CLUSTER-agent-0" ]]
work=$(mktemp -d)
store="backup-s3-$K3D_TEST_CLUSTER"
cleanup() {
  docker rm -f "$store" > /dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

# Run the production scripts with the real CRI and PostgreSQL on the k3d worker.
cat > "$work/k3s" <<'EOF'
#!/usr/bin/env bash
exec docker exec -i "$BACKUP_TEST_WORKER" k3s "$@"
EOF
chmod 700 "$work/k3s"
export PATH="$work:$PATH"

# Only object storage is emulated. Credentials and endpoint belong to this test.
docker run -d --name "$store" -p 127.0.0.1::5000 \
  motoserver/moto:5.2.1@sha256:fe6575dcd878842124f05d20e4ffde2d1126e1e38ad03e196353b9e53649bcdf > /dev/null
export AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_ENDPOINT_URL="http://$(docker port "$store" 5000/tcp)"
AWS_ACCESS_KEY_ID=$(openssl rand -hex 10)
AWS_SECRET_ACCESS_KEY=$(openssl rand -hex 24)
unset AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true AWS_PAGER=
export BACKUP_BUCKET="$ns-backups-ci"
curl -fsS --retry 20 --retry-all-errors --retry-delay 1 "$AWS_ENDPOINT_URL/" > /dev/null
aws s3api create-bucket --bucket "$BACKUP_BUCKET" > /dev/null

url="${K3D_INGRESS_URL:?Test cluster must expose Traefik}/api/items"
id=$(curl -fsS --json '{"title":"Archive scholarship","description":"Before backup"}' "$url" | jq -er '.id | numbers')
[[ "$id" =~ ^[0-9]+$ ]]
openssl rand 32768 > "$work/proof.bin"
curl -fsS -F "file=@$work/proof.bin;type=application/octet-stream" "$url/$id/attachment" > /dev/null
digest=$(sha256sum "$work/proof.bin" | cut -d ' ' -f 1)

sql() {
  kubectl -n "$ns" exec "$pod" -- psql -XqAt -v ON_ERROR_STOP=1 -U postgres -d "$1" -c "$2"
}
snapshot="SELECT to_jsonb(i) || jsonb_build_object('bytes', octet_length(b.content),
                 'sha256', encode(sha256(b.content), 'hex'))
          FROM public.items i JOIN public.attachment_blobs b ON b.item_id = i.id WHERE i.id = $id"
before=$(sql campus "$snapshot")
jq -e --arg digest "$digest" '
  .title == "Archive scholarship" and .description == "Before backup" and
  .attachment_name == "proof.bin" and .bytes == 32768 and .sha256 == $digest
' <<< "$before" > /dev/null

key=$(bash ops/backup.sh)
aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$key" | jq -e '.ContentLength > 0' > /dev/null
# Simulate data loss only in the disposable test cluster. Its FK also removes the blob.
sql campus "DELETE FROM public.items WHERE id = $id"
remaining="SELECT (SELECT count(*) FROM public.items WHERE id = $id)
                + (SELECT count(*) FROM public.attachment_blobs WHERE item_id = $id)"
[[ $(sql campus "$remaining") == 0 ]]
target=campus_restore_ci
bash ops/restore.sh "$key" "$target"
[[ $(sql "$target" "$snapshot") == "$before" ]]

for occupied in "$target" campus; do
  if bash ops/restore.sh "$key" "$occupied"; then
    echo "Unexpectedly restored into existing database: $occupied" >&2
    exit 1
  fi
done
[[ $(sql "$target" "$snapshot") == "$before" ]]
[[ $(sql campus "$remaining") == 0 ]]
echo "Recovered the application and its 32768-byte attachment from S3 into a separate database; SHA-256: $digest"
