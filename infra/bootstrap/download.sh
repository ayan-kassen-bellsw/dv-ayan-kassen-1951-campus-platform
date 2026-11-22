#!/usr/bin/env bash
set -euo pipefail

bootstrap=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$bootstrap/version")
cache="$bootstrap/../.artifacts/$version"
base="https://github.com/k3s-io/k3s/releases/download/${version/+/%2B}"
mkdir -p "$cache"
cd "$cache"

# Download into a temporary file. Terraform can only see verified, complete assets.
tmp=$(mktemp .download.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
while read -r digest name; do
  if printf '%s  %s\n' "$digest" "$name" | sha256sum --check --status 2>/dev/null; then
    continue
  fi
  curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
    --retry 3 --output "$tmp" "$base/$name"
  printf '%s  %s\n' "$digest" "$tmp" | sha256sum --check --status
  mv -f -- "$tmp" "$name"
done < "$bootstrap/release.sha256"
sha256sum --check "$bootstrap/release.sha256"
