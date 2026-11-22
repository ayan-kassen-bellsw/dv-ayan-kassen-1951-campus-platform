#!/usr/bin/env bash
# Run both rendered user-data scripts against local files. No AWS, root or systemd required.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 SERVER_USER_DATA AGENT_USER_DATA" >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export MOCK_S3="$work/s3" MOCK_LOG="$work/calls"
mkdir -p "$work/bin" "$MOCK_S3/cluster"
touch "$MOCK_LOG"
export PATH="$work/bin:$PATH"

cat > "$work/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --region && $3 == s3 && $4 == cp && $5 == --only-show-errors ]]
src=$6
dest=$7
if [[ $src == s3://* ]]; then
  cp "$MOCK_S3/${src#s3://*/}" "$dest"
else
  [[ $dest == s3://*/cluster/agent-token && $# == 7 && -z ${FAIL_PUT:-} ]]
  cp "$src" "$MOCK_S3/${dest#s3://*/}"
  echo put >> "$MOCK_LOG"
fi
MOCK
cat > "$work/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "systemctl $*" >> "$MOCK_LOG"
MOCK
printf '#!/bin/sh\nexit 0\n' > "$work/bin/modprobe"
cp "$work/bin/modprobe" "$work/bin/sysctl"
chmod +x "$work"/bin/*

prepare_host() {
  local root="$work/$1" rendered=$2
  bash -n "$rendered"
  mkdir -p "$root"/etc/{modules-load.d,sysctl.d,systemd/system}
  sed -e "s|/usr/local/|$root/usr/local/|g" -e "s|/var/lib/|$root/var/lib/|g" -e "s|/etc/|$root/etc/|g" \
    "$rendered" > "$root/cloud-init.sh"
  bash "$root/cloud-init.sh"
  bash -n "$root/usr/local/sbin/k3s-bootstrap"
  grep -Fxq 'Delegate=yes' "$root/etc/systemd/system/k3s.service"
  grep -Fxq 'Restart=always' "$root/etc/systemd/system/k3s.service"
  grep -Eq '^OnUnitActiveSec=' "$root/etc/systemd/system/k3s-token-sync.timer"
}
prepare_host server "$1"
prepare_host agent "$2"
server="$work/server/usr/local/sbin/k3s-bootstrap"
agent="$work/agent/usr/local/sbin/k3s-bootstrap"
version=$(sed -n "s/^version='\([^']*\)'$/\1/p" "$server")
[[ -n $version ]]
release="$MOCK_S3/releases/$version"
mkdir -p "$release"
cat > "$release/k3s" <<'MOCK'
#!/usr/bin/env bash
echo "k3s $*" >> "$MOCK_LOG"
MOCK
archive=k3s-airgap-images-amd64.tar.zst
echo 'Test air-gap images' > "$release/$archive"
(cd "$release" && sha256sum k3s "$archive" > sha256sum-amd64.txt)

must_fail() {
  if "$@" > "$work/error" 2>&1; then
    echo "Unexpected success: $1 $2" >&2
    exit 1
  fi
}
must_fail "$server" start
grep -Fq 'Release manifest checksum failed' "$work/error"
# Use our fixture checksum only inside the disposable host copies; the deployed script pins the upstream hash.
fixture_digest=$(sha256sum < "$release/sha256sum-amd64.txt" | cut -d ' ' -f1)
sed -i "s/^manifest_sha256='[0-9a-f]\{64\}'$/manifest_sha256='$fixture_digest'/" "$server" "$agent"
echo 'tampered' >> "$release/$archive"
must_fail "$server" start
grep -Fq "Checksum failed for $archive" "$work/error"
[[ ! -e $work/server/usr/local/bin/k3s ]]
echo 'Test air-gap images' > "$release/$archive"
"$server" start
cmp "$release/$archive" "$work/server/var/lib/rancher/k3s/agent/images/$archive"
must_fail "$agent" start
must_fail "$agent" sync-token

config="$work/server/etc/rancher/k3s"
generated="$work/server/var/lib/rancher/k3s/server/agent-token"
remote="$MOCK_S3/cluster/agent-token"
mkdir -p "$(dirname "$generated")"
[[ $(stat -c %a "$config/agent-password") == 600 ]]
make_token() { printf 'K10%064x::%s:%s\n' "$1" "$2" "$3"; }
password=$(<"$config/agent-password")
make_token 1 server "$password" > "$generated"
must_fail "$server" sync-token
mv "$generated" "$generated.backup"
ln -s "$generated.backup" "$generated"
must_fail "$server" sync-token
[[ ! -e $remote ]]
rm "$generated"
make_token 1 node "$password" > "$generated"
FAIL_PUT=1 must_fail "$server" sync-token
"$server" sync-token
"$server" sync-token
[[ $(grep -cx put "$MOCK_LOG") == 1 ]]
cmp "$generated" "$remote"
"$agent" sync-token
"$agent" start
joined="$work/agent/etc/rancher/k3s/join-token"
[[ $(stat -c %a "$joined") == 600 ]]
cmp "$generated" "$joined"
grep -Eq '^k3s agent --server https://[^ ]+:6443 --token-file .+ --with-node-id' "$MOCK_LOG"

# A server replacement changes the CA. The agent must reread the new token once.
make_token 2 node "$password" > "$generated"
"$server" sync-token
"$agent" sync-token
"$agent" sync-token
cmp "$generated" "$joined"
[[ $(grep -cx 'systemctl --no-block restart k3s.service' "$MOCK_LOG") == 1 ]]
"$server" start
[[ $(<"$config/agent-password") == "$password" ]]
if grep -Fq -f "$config/agent-password" "$MOCK_LOG"; then exit 1; fi
echo 'Bootstrap checks passed for checksum rejection, offline installation, agent-only tokens, retry and replacement.'
