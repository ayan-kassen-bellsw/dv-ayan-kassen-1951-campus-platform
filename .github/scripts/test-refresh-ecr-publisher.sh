#!/usr/bin/env bash
set -euo pipefail
umask 077

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export PATH="$work:$PATH" RECEIPT="$work/saved"
export TEST_REGISTRY=012345678901.dkr.ecr.us-east-1.amazonaws.com
export TEST_ECR_PASSWORD
TEST_ECR_PASSWORD=$(openssl rand -hex 24)
cat > "$work/aws" <<'BASH'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  'ecr describe-repositories') echo "$TEST_REGISTRY/dv-ayan-kassen-1951-scholarship-applications" ;;
  'ecr get-login-password') echo "$TEST_ECR_PASSWORD" ;;
  *) exit 1 ;;
esac
BASH
cat > "$work/gh" <<'BASH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'variable get ECR_REGISTRY --repo ayan-kassen-bellsw/dv-ayan-kassen-1951-campus-platform')
    echo "${GH_REGISTRY_OVERRIDE:-$TEST_REGISTRY}" ;;
  'secret set ECR_PUSH_PASSWORD --repo ayan-kassen-bellsw/dv-ayan-kassen-1951-campus-platform --env ecr-publish')
    [[ $(cat) == "$TEST_ECR_PASSWORD" ]] && touch "$RECEIPT" ;;
  *) exit 1 ;;
esac
BASH
cat > "$work/curl" <<'BASH'
#!/usr/bin/env bash
set -eu
[[ ${!#} == "https://$TEST_REGISTRY/v2/dv-ayan-kassen-1951-scholarship-applications/manifests/v0.1.0" ]]
[[ "$*" != *"$TEST_ECR_PASSWORD"* ]]
[[ $(cat) == "Authorization: Basic $(printf 'AWS:%s' "$TEST_ECR_PASSWORD" | base64 | tr -d '\r\n')" ]]
printf '%s' "${REGISTRY_STATUS:-200}"
BASH
chmod +x "$work/"{aws,gh,curl}
refresh=(bash "$(dirname "$0")/../../ops/refresh-ecr-publisher.sh")
if GH_REGISTRY_OVERRIDE=wrong "${refresh[@]}"; then exit 1; fi
if REGISTRY_STATUS=403 "${refresh[@]}"; then exit 1; fi
[[ ! -e $RECEIPT ]]
"${refresh[@]}"
[[ -f $RECEIPT ]]
