#!/usr/bin/env bash
set -euo pipefail

version=0.76.2
sha256=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
archive="$RUNNER_TEMP/trivy.tar.gz"
curl -fsSL --retry 3 -o "$archive" "https://github.com/aquasecurity/trivy/releases/download/v$version/trivy_${version}_Linux-64bit.tar.gz"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check
tar xzf "$archive" -C "$RUNNER_TEMP" trivy
