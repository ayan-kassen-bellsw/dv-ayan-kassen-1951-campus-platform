#!/usr/bin/env bash
set -euo pipefail
umask 077

if (( $# == 0 )); then
  echo 'Usage: bash .github/scripts/test-k3s.sh TEST_SCRIPT [TEST_SCRIPT ...]' >&2
  exit 2
fi

work=$(mktemp -d)
export KUBECONFIG="$work/kubeconfig"
K3D_TEST_CLUSTER="scholar-e2e-$(openssl rand -hex 5)"
export K3D_TEST_CLUSTER

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )) && [[ -s "$KUBECONFIG" ]]; then
    kubectl --request-timeout=5s get pods,pvc -A || true
  fi
  if [[ -x "$work/k3d" ]]; then
    "$work/k3d" cluster delete "$K3D_TEST_CLUSTER" || status=1
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 \
  https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64 -o "$work/k3d"
echo "06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0  $work/k3d" | sha256sum --check
chmod +x "$work/k3d"
export PATH="$work:$PATH"
version=$(tr -d '\r\n' < infra/bootstrap/version)
k3d cluster create "$K3D_TEST_CLUSTER" --agents 1 --image "rancher/k3s:${version/+/-}" \
  --api-port 127.0.0.1:0 --port '127.0.0.1::80@loadbalancer' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait --timeout 5m
k3d kubeconfig get "$K3D_TEST_CLUSTER" > "$KUBECONFIG"
lb="k3d-$K3D_TEST_CLUSTER-serverlb"
# k3d records the requested port (zero), so read Docker's actual loopback binding.
kubectl config set-cluster "k3d-$K3D_TEST_CLUSTER" --server="https://$(docker port "$lb" 6443/tcp)"
K3D_INGRESS_URL="http://$(docker port "$lb" 80/tcp)"
export K3D_INGRESS_URL
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl get nodes
for test_script in "$@"; do
  bash "$test_script"
done
