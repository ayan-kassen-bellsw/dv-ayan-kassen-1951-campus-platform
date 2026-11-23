#!/usr/bin/env bash
set -euo pipefail
umask 077
ns=dv-ayan-kassen-1951
unit=$ns-main-deploy
credentials="/run/$unit-credentials"
install -d -o root -g root -m 0711 "$credentials"
token=$(mktemp "$credentials/.token.XXXXXXXX")
trap 'rm -f -- "$token"' EXIT
HOME=/root /usr/local/bin/k3s kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
  -n "$ns" create token "$unit" --duration=10m > "$token"
chmod 0400 "$token"
service_uid=$(id -u scholarship-cd)
chown "$service_uid" "$token"
mv -fT -- "$token" "$credentials/token"
