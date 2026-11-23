#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $(kubectl config current-context) == "k3d-${K3D_TEST_CLUSTER:?Run with test-k3s.sh}" ]]
ns=dv-ayan-kassen-1951
db=$ns-postgres
pod=$db-0
k=(kubectl --namespace "$ns")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

kubectl apply -k k8s/postgres
mkdir "$work/db"
for role in postgres admin rw ro; do
  printf 'Aa1%s' "$(openssl rand -hex 16)" > "$work/db/$role-password"
done
"${k[@]}" create secret generic "$ns-postgres-credentials" --from-file="$work/db"
printf '%s' "$(openssl rand -hex 32)" > "$work/secret-key"
"${k[@]}" create secret generic "$ns-app-credentials" --from-file="rw-password=$work/db/rw-password" --from-file="$work/secret-key"
"${k[@]}" rollout status "statefulset/$db" --timeout=5m

# Authenticate over TCP, using the actual projected Secret in the database container.
sql() {
  local role=$1 key=$2 statement=$3
  "${k[@]}" exec "$pod" -- bash -ec '
    export PGPASSWORD="$(cat "/run/scholarship-passwords/$2-password")"
    exec psql -XqwAt -h 127.0.0.1 -U "$1" -d campus -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "$3"
  ' -- "$role" "$key" "$statement"
}
denied() {
  if sql "$@" > "$work/sql.log" 2>&1; then
    echo "Unexpectedly permitted SQL for $1" >&2
    return 1
  fi
  # SQLSTATE 42501 distinguishes a privilege denial from an unavailable server or bad SQL.
  grep -q '42501' "$work/sql.log"
}

sql admin admin 'BEGIN; CREATE TABLE public.permission_probe (id integer); ROLLBACK'
id=$(sql app_rw rw "INSERT INTO items(title, description, created_at) VALUES ('Test scholarship', 'PVC check', now()) RETURNING id")
[[ "$id" =~ ^[0-9]+$ ]]
[[ $(sql app_ro ro "SELECT title FROM public.items WHERE id=$id") == 'Test scholarship' ]]
denied app_ro ro "BEGIN; INSERT INTO public.items(title, description, created_at) VALUES ('Forbidden', '', now()); ROLLBACK"
denied app_rw rw 'BEGIN; DROP TABLE public.items CASCADE; ROLLBACK'

# Run the installed provisioning path against a weak copy. The real Secret and role passwords stay intact.
"${k[@]}" exec "$pod" -- bash -ec '
  work=$(mktemp -d)
  trap '\''rm -rf -- "$work"'\'' EXIT
  cp /run/scholarship-passwords/*-password "$work/"
  rm -- "$work/rw-password"
  printf "%s" short > "$work/rw-password"
  if DB_CREDENTIAL_DIR="$work" /opt/scholarship-db/reconcile.sh > "$work/result" 2>&1; then exit 1; fi
  grep -q "rw-password must have at least 16" "$work/result"
'

old_uid=$("${k[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}')
claim=$("${k[@]}" get pod "$pod" -o jsonpath='{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
pvc_uid=$("${k[@]}" get pvc "$claim" -o jsonpath='{.metadata.uid}')
[[ -n "$pvc_uid" ]]
"${k[@]}" delete pod "$pod" --timeout=90s
"${k[@]}" rollout status "statefulset/$db" --timeout=3m
[[ $("${k[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}') != "$old_uid" ]]
[[ $("${k[@]}" get pvc "$claim" -o jsonpath='{.metadata.uid}') == "$pvc_uid" ]]
[[ $(sql app_ro ro "SELECT description FROM public.items WHERE id=$id") == 'PVC check' ]]
echo 'PostgreSQL passed TCP role checks, weak credential rejection and persistence across Pod replacement.'
