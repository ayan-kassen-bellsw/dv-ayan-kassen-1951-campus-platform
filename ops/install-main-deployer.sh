#!/usr/bin/env bash
set -euo pipefail
umask 022
ns=dv-ayan-kassen-1951
unit=$ns-main-deploy
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $EUID != 0 || $# != 1 || ! $1 =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com$ ]]; then
  echo 'Usage on the k3s server: sudo bash ops/install-main-deployer.sh <ECR registry hostname>' >&2
  exit 2
fi
kube=(/usr/local/bin/k3s kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml -n "$ns")
command -v aws >/dev/null
"${kube[@]}" get deployment "$ns-app" >/dev/null
printf '%s\n' 'u scholarship-cd - "Scholarship application deployer" /nonexistent /sbin/nologin' | systemd-sysusers -
"${kube[@]}" apply -f "$root/k8s/app/host/main-deploy-rbac.yaml"
install -d -m 0755 "/etc/$unit" "/usr/local/lib/$unit"
tmp=$(mktemp -d "/etc/$unit/.install.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
"${kube[@]}" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > "$tmp/ca.crt"
test -s "$tmp/ca.crt"
printf 'ECR_REGISTRY=%s\nECR_REGISTRY_ID=%s\n' "$1" "${1%%.*}" > "$tmp/registry.env"
for config in ca.crt registry.env; do
  install -m 0644 "$tmp/$config" "/etc/$unit/$config"
done
install -m 0644 "$root/ops/"{main-deploy-token.sh,reconcile_main.py} "/usr/local/lib/$unit/"
install -m 0644 "$root/k8s/app/host/$unit."{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now "$unit.timer"
systemctl start "$unit.service"
