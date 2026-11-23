#!/usr/bin/env bash
set +x
set -euo pipefail
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off

if (( $# < 1 || $# > 2 )); then
  echo "Usage: bash ops/verify-ecr-pull.sh ECR_URI@sha256:DIGEST [private-agent-IP]" >&2
  exit 2
fi
image=$1
agent_ip=${2:-10.56.2.10}
pattern='^([0-9]{12})\.dkr\.ecr\.(us-east-1)\.amazonaws\.com/([a-z0-9][a-z0-9._/-]*)@(sha256:[a-f0-9]{64})$'
if [[ ! $image =~ $pattern ]]; then
  echo 'Expected a private us-east-1 ECR repository URI with a manifest digest.' >&2
  exit 2
fi
account=${BASH_REMATCH[1]}
region=${BASH_REMATCH[2]}
repository=${BASH_REMATCH[3]}
digest=${BASH_REMATCH[4]}
registry=${image%%/*}

if command -v kubectl >/dev/null; then
  kube=(kubectl)
else
  kube=(/usr/local/bin/k3s kubectl)
fi

# Depending on containerd's version, Kubernetes can report the manifest or the image config as imageID.
config_digest=$(aws ecr batch-get-image --region "$region" --registry-id "$account" \
  --repository-name "$repository" --image-ids "imageDigest=$digest" --output json |
  python3 -c '
import json, re, sys
images = json.load(sys.stdin)["images"]
if not images or any(image["imageId"]["imageDigest"] != sys.argv[1] for image in images):
    sys.exit("ECR did not return the requested image")
manifests = {image["imageManifest"] for image in images}
if len(manifests) != 1:
    sys.exit("ECR returned inconsistent manifests for the same digest")
manifest = json.loads(manifests.pop())
config = manifest.get("config", {}).get("digest", "")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", config):
    sys.exit("Supply the linux/amd64 image manifest digest, including for multi-platform releases")
print(config)
' "$digest")

# Use the scheduler and verify the final assignment; a successful run on the public server proves nothing about the agent.
node=$("${kube[@]}" get nodes -o json | python3 -c '
import ipaddress, json, sys
ip = str(ipaddress.IPv4Address(sys.argv[1]))
matches = []
for node in json.load(sys.stdin)["items"]:
    labels = node["metadata"]["labels"]
    if "node-role.kubernetes.io/control-plane" in labels or "node-role.kubernetes.io/master" in labels:
        continue
    if node.get("spec", {}).get("unschedulable") or labels.get("kubernetes.io/arch") != "amd64":
        continue
    if not any(c["type"] == "Ready" and c["status"] == "True" for c in node["status"]["conditions"]):
        continue
    if any(a["type"] == "InternalIP" and a["address"] == ip for a in node["status"]["addresses"]):
        matches.append(node["metadata"]["name"])
if len(matches) != 1:
    sys.exit("Expected one schedulable Ready amd64 agent with the requested InternalIP")
print(matches[0])
' "$agent_ip")

namespace=$("${kube[@]}" create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  generateName: dv-ayan-kassen-1951-ecr-check-
YAML
)
cleanup() {
  "${kube[@]}" delete namespace "$namespace" --ignore-not-found --timeout=90s >/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
k=("${kube[@]}" --namespace "$namespace")

# Request the token on the admin host. Stream it straight to the temporary Secret without putting it in arguments or a file.
aws ecr get-authorization-token --region "$region" --query 'authorizationData[0].authorizationToken' --output text |
  python3 -c '
import base64, json, sys
token = sys.stdin.read().strip()
if not base64.b64decode(token, validate=True).startswith(b"AWS:"):
    sys.exit("ECR did not return a registry token")
config = {"auths": {sys.argv[1]: {"auth": token}}}
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "ecr-pull"},
                  "type": "kubernetes.io/dockerconfigjson", "stringData": {".dockerconfigjson": json.dumps(config)}}))
' "$registry" | "${k[@]}" create -f - >/dev/null

"${k[@]}" wait --for=create serviceaccount/default --timeout=40s >/dev/null
"${k[@]}" create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: pull-check
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchFields:
              - key: metadata.name
                operator: In
                values: ["$node"]
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: 300
  imagePullSecrets:
    - name: ecr-pull
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: check
      image: "$image"
      imagePullPolicy: Always
      command: ["python", "-c", "import os; assert os.geteuid() == 10001; import app; print('ecr-pull-ok')"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
YAML

if ! "${k[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/pull-check --timeout=310s >/dev/null; then
  "${k[@]}" get events --field-selector involvedObject.name=pull-check -o custom-columns=REASON:.reason >&2
  exit 1
fi
[[ $("${k[@]}" logs pull-check) == ecr-pull-ok ]]
runtime_digest=$("${k[@]}" get pod pull-check -o json | python3 -c '
import json, re, sys
pod = json.load(sys.stdin)
check, = pod["status"]["containerStatuses"]
if pod["spec"]["nodeName"] != sys.argv[1] or check["state"]["terminated"]["exitCode"] != 0:
    sys.exit("Pod did not complete on the requested agent")
match = re.search(r"(?:^|@|://)(sha256:[0-9a-f]{64})$", check["imageID"])
if not match or match.group(1) not in sys.argv[2:]:
    sys.exit("Running container does not match the ECR manifest or config digest")
print(match.group(1))
' "$node" "$digest" "$config_digest")

# A new namespace prevents events from earlier runs satisfying this check.
pulled=false
for ((attempt=0; attempt<10; attempt++)); do
  reasons=$("${k[@]}" get events --field-selector 'involvedObject.kind=Pod,involvedObject.name=pull-check' \
    -o jsonpath='{range .items[*]}{.reason}{"\n"}{end}')
  if grep -qx 'Pulling' <<< "$reasons" && grep -qx 'Pulled' <<< "$reasons"; then
    pulled=true
    break
  fi
  sleep 2
done
[[ $pulled == true ]] || { echo 'Missing Pulling/Pulled events for the probe.' >&2; exit 1; }

cleanup
trap - EXIT
printf 'Verified UTC=%s agent=%s internal_ip=%s manifest=%s runtime=%s events=Pulling,Pulled result=ecr-pull-ok\n' \
  "$(date -u +%FT%TZ)" "$node" "$agent_ip" "$digest" "$runtime_digest"
