#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

namespace=dv-ayan-kassen-1951
app=dv-ayan-kassen-1951-app
if command -v kubectl >/dev/null 2>&1; then
  kube=(kubectl)
else
  kube=(/usr/local/bin/k3s kubectl)
fi

if [[ $# != 1 || ! $1 =~ ^(render|apply|refresh-pull)$ ]]; then
  echo 'Usage: deploy-app.sh render|apply|refresh-pull' >&2
  exit 2
fi

if [[ $1 == refresh-pull ]]; then
  export AWS_PAGER=""
  # Use the host instance role. The Docker password travels through a pipe directly to Kubernetes.
  aws ecr get-authorization-token --region us-east-1 --output json |
    python3 -c '
import base64, json, re, sys
entry, = json.load(sys.stdin)["authorizationData"]
endpoint = entry["proxyEndpoint"]
token = entry["authorizationToken"]
if not re.fullmatch(r"https://[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com", endpoint):
    sys.exit("Unexpected ECR endpoint")
if not base64.b64decode(token, validate=True).startswith(b"AWS:"):
    sys.exit("Invalid ECR token")
config = json.dumps({"auths": {endpoint[8:]: {"auth": token}}}).encode()
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
    "metadata": {"name": "dv-ayan-kassen-1951-ecr-pull", "namespace": sys.argv[1]},
    "data": {".dockerconfigjson": base64.b64encode(config).decode("ascii")},
}))
' "$namespace" | "${kube[@]}" apply --server-side --field-manager=ecr-pull-refresh --force-conflicts -f -
  exit 0
fi

: "${APP_IMAGE:?Set the published image URI with its digest, or a preloaded local image tag}"
: "${GIT_SHA:?Set the full commit SHA used to build the image}"
: "${APP_VERSION:?Set the release version or build identifier}"
: "${APP_OWNER:?Set the student name and full student ID}"
mode=${APP_MODE:-cloud}
[[ $GIT_SHA =~ ^[0-9a-f]{40}$ ]] || { echo 'GIT_SHA must be a full Git SHA' >&2; exit 2; }
if [[ $APP_OWNER == *$'\n'* || $APP_OWNER == *$'\r'* || ! $APP_VERSION =~ ^[a-zA-Z0-9._+-]+$ ]]; then
  echo 'Provide a single-line APP_OWNER and a version identifier' >&2
  exit 2
fi
case $mode in
  cloud)
    if [[ ! $APP_IMAGE =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/dv-ayan-kassen-1951-scholarship-applications@sha256:[0-9a-f]{64}$ ]]; then
      echo 'Cloud deployment requires the project repository URI pinned to its ECR digest' >&2
      exit 2
    fi ;;
  local)
    if [[ ! $APP_IMAGE =~ ^[a-z0-9./:_-]+:[A-Za-z0-9_.-]+$ || $APP_IMAGE == *:latest ]]; then
      echo 'Local testing requires an explicit image tag preloaded into every schedulable node' >&2
      exit 2
    fi ;;
  *) echo 'APP_MODE must be cloud or local' >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -R "$repo/k8s/app" "$work/manifests"
printf 'APP_OWNER=%s\nAPP_VERSION=%s\nGIT_SHA=%s\n' "$APP_OWNER" "$APP_VERSION" "$GIT_SHA" > "$work/release.env"
cat > "$work/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $namespace
resources: [manifests/$mode]
configMapGenerator:
  - name: dv-ayan-kassen-1951-app-config
    namespace: $namespace
    behavior: merge
    envs: [release.env]
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: $app
      spec:
        template:
          spec:
            containers:
              - name: app
                image: "$APP_IMAGE"
                env:
                  - name: GIT_SHA
                    value: "$GIT_SHA"
                  - name: APP_VERSION
                    value: "$APP_VERSION"
YAML
"${kube[@]}" kustomize "$work" > "$work/rendered.yaml"
if [[ $1 == render ]]; then
  cat "$work/rendered.yaml"
else
  "${kube[@]}" apply -f "$work/rendered.yaml"
  "${kube[@]}" -n "$namespace" rollout status "deployment/$app" --timeout=5m
fi
