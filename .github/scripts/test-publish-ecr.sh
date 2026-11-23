#!/usr/bin/env bash
set -euo pipefail

# Exercise immutable tags and registry errors without an AWS session or Docker daemon.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
scripts=$(cd "$(dirname "$0")" && pwd)
bash "$scripts/test-release-ref.sh"
export REGISTRY_FIXTURE="$work/manifests"
export REVISION=0123456789abcdef0123456789abcdef01234567
export ECR_PUSH_PASSWORD
ECR_PUSH_PASSWORD=$(openssl rand -hex 16)
unset GITHUB_ACTIONS
mkdir "$REGISTRY_FIXTURE" "$work/bin"
export PATH="$work/bin:$PATH"
cat > "$work/bin/curl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
method=GET
ref=${!#}
file="$REGISTRY_FIXTURE/${ref##*/}"
case $ref in
  http://ingress.test/readyz) echo '{"ready":true,"checks":{"db":true,"storage":true}}'; exit ;;
  http://ingress.test/info)
    calls=$(wc -l < "$REGISTRY_FIXTURE/probes")
    if [[ "$*" == *'Host: prod.scholarships.test'* ]]; then
      version=v0.2.0
      case $calls in
        0) version=v0.1.0; host=dv-ayan-kassen-1951-prod-old ;;
        1) host=dv-ayan-kassen-1951-app-main ;;
        2) host=dv-ayan-kassen-1951-prod-one ;;
        3) host=dv-ayan-kassen-1951-prod-two ;;
        *) exit 1 ;;
      esac
      echo "$host" >> "$REGISTRY_FIXTURE/probes"
      printf '{"git_sha":"%s","hostname":"%s","version":"%s"}\n' "$REVISION" "$host" "$version"
      exit
    fi
    case $calls in
      0) sha=$REVISION; host=pod-a ;;
      1) sha=old; host=pod-old ;;
      2|3) sha=$REVISION; host=pod-b ;;
      4) sha=$REVISION; host=pod-a ;;
      *) exit 1 ;;
    esac
    echo "$host" >> "$REGISTRY_FIXTURE/probes"
    printf '{"git_sha":"%s","hostname":"%s"}\n' "$sha" "$host"
    exit ;;
esac
while (( $# > 0 )); do
  case $1 in
    --output) out=$2; shift ;;
    --data-binary) src=${2#@}; shift ;;
    --request) method=$2; shift ;;
  esac
  shift
done
if [[ -n ${FAIL_HTTP:-} ]]; then printf '%s' "$FAIL_HTTP"
elif [[ "$method" == PUT && ! -e "$file" ]]; then cp "$src" "$file"; printf '201'
elif [[ -e "$file" ]]; then cp "$file" "$out"; printf '200'
else printf '404'; fi
BASH
cat > "$work/bin/docker" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  image) echo "${LOCAL_REVISION:-$REVISION}" ;;
  tag) : ;;
  push)
    [[ ! -e "$REGISTRY_FIXTURE/$REVISION" ]]
    echo '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}' > "$REGISTRY_FIXTURE/$REVISION"
    echo push >> "$REGISTRY_FIXTURE/pushes" ;;
  *) exit 1 ;;
esac
BASH
chmod +x "$work/bin/"*
publish=(bash "$(dirname "$0")/publish-ecr.sh" '012345678901.dkr.ecr.us-east-1.amazonaws.com/dv-ayan-kassen-1951-scholarship-applications' "$REVISION")

if "${publish[@]}" v0.1.0; then exit 1; fi
if LOCAL_REVISION=bad "${publish[@]}"; then exit 1; fi
if FAIL_HTTP=401 "${publish[@]}"; then exit 1; fi
if FAIL_HTTP=403 "${publish[@]}"; then exit 1; fi
"${publish[@]}"
"${publish[@]}"
[[ $(wc -l < "$REGISTRY_FIXTURE/pushes") == 1 ]]
"${publish[@]}" v0.1.0
"${publish[@]}" v0.1.0
cmp "$REGISTRY_FIXTURE/$REVISION" "$REGISTRY_FIXTURE/v0.1.0"
printf 'other digest' > "$REGISTRY_FIXTURE/v1.0.0"
if "${publish[@]}" v1.0.0; then exit 1; fi
if "${publish[@]}" v01.0.0; then exit 1; fi
prod_marker="deploy-prod-6-$REVISION-v0.2.0"
"${publish[@]}" v0.2.0
"${publish[@]}" "$prod_marker"
"${publish[@]}" "$prod_marker"
cmp "$REGISTRY_FIXTURE/$prod_marker" "$REGISTRY_FIXTURE/v0.2.0"
if "${publish[@]}" "deploy-prod-6-$REVISION-v00.2.0"; then exit 1; fi

# A retry may reuse the marker; earlier CIs and tags for another SHA cannot promote it.
marker="deploy-main-52-$REVISION"
if "${publish[@]}" "deploy-main-52-${REVISION//0/1}"; then exit 1; fi
if "${publish[@]}" "deploy-main-00-$REVISION"; then exit 1; fi
cat > "$work/bin/git" <<'BASH'
#!/usr/bin/env bash
[[ "$*" == 'ls-remote --exit-code origin refs/heads/main' ]] || exit 2
printf '%s\trefs/heads/main\n' "$(cat "$REGISTRY_FIXTURE/main")"
BASH
cat > "$work/bin/sleep" <<'BASH'
#!/usr/bin/env bash
# Abort a broken poll loop rather than waiting for the real ten-minute timeout.
[[ $(wc -l < "$REGISTRY_FIXTURE/probes") -lt 5 ]]
BASH
chmod +x "$work/bin/git" "$work/bin/sleep"
export SOURCE_SHA=$REVISION CI_RUN_NUMBER=52 K3S_APP_URL=http://ingress.test
export ECR_REGISTRY=012345678901.dkr.ecr.us-east-1.amazonaws.com
export GITHUB_OUTPUT="$work/outputs"
deploy=(bash "$(dirname "$0")/deploy-main.sh")
printf '%s\n' superseded > "$REGISTRY_FIXTURE/main"
"${deploy[@]}" mark
[[ ! -f "$GITHUB_OUTPUT" && ! -f "$REGISTRY_FIXTURE/$marker" ]]
printf '%s\n' "$REVISION" > "$REGISTRY_FIXTURE/main"
if K3S_APP_URL='http://user@ingress.test' "${deploy[@]}" mark; then exit 1; fi
"${deploy[@]}" mark
"${deploy[@]}" mark
cmp "$REGISTRY_FIXTURE/$REVISION" "$REGISTRY_FIXTURE/$marker"
[[ $(head -n 1 "$GITHUB_OUTPUT") == marked=true ]]
: > "$REGISTRY_FIXTURE/probes"
"${deploy[@]}" verify
[[ $(wc -l < "$REGISTRY_FIXTURE/probes") -eq 5 ]]
printf '%s\n' superseded > "$REGISTRY_FIXTURE/main"
"${deploy[@]}" verify
[[ $(wc -l < "$REGISTRY_FIXTURE/probes") -eq 5 ]]
bash "$scripts/test-refresh-ecr-publisher.sh"
: > "$REGISTRY_FIXTURE/probes"
RELEASE_VERSION=v0.2.0 bash "$scripts/verify-ingress.sh" prod
[[ $(wc -l < "$REGISTRY_FIXTURE/probes") -eq 4 ]]
echo "ECR publication, immutable promotion and both deployment checks passed."
