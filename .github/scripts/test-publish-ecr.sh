#!/usr/bin/env bash
set -euo pipefail

# Exercise immutable tags and registry errors without an AWS session or Docker daemon.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
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
"${publish[@]}"
"${publish[@]}"
[[ $(wc -l < "$REGISTRY_FIXTURE/pushes") == 1 ]]
"${publish[@]}" v0.1.0
"${publish[@]}" v0.1.0
cmp "$REGISTRY_FIXTURE/$REVISION" "$REGISTRY_FIXTURE/v0.1.0"
printf 'other digest' > "$REGISTRY_FIXTURE/v1.0.0"
if "${publish[@]}" v1.0.0; then exit 1; fi
if "${publish[@]}" v01.0.0; then exit 1; fi
echo "ECR publication and immutable promotion checks passed."
