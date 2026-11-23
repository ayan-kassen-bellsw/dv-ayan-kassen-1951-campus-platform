#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# -ge 2 ]] || { echo "Usage: $0 <expected main image> <kubectl command...>" >&2; exit 2; }
image=$1
shift
ns=dv-ayan-kassen-1951
root=$(cd "$(dirname "$0")/.." && pwd)
k=("$@" -n "$ns")
"${k[@]}" apply -f "$root/k8s/postgres/network-policy.yaml" -f "$root/k8s/app/prod/route.yaml"

# Subsequent approved releases own this Deployment's version, digest and replica count.
existing=$("${k[@]}" get deployment "$ns-prod" --ignore-not-found -o name)
if [[ -z $existing ]]; then
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  "${k[@]}" get deployment "$ns-app" -o json > "$work/main.json"
  "${k[@]}" create --dry-run=client -f "$root/k8s/app/base/deployment.yaml" -o json |
    python3 "$root/ops/render_prod.py" "$work/main.json" "$image" > "$work/prod.json"
  "${k[@]}" create -f "$work/prod.json"
fi
