#!/usr/bin/env bash
set -euo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git init -q -b main "$work/source"
git -C "$work/source" config user.email fixture@example.invalid
git -C "$work/source" config user.name "Release fixture"
git -C "$work/source" commit -qm initial --allow-empty
git -C "$work/source" tag v0.1.0
git -C "$work/source" tag -a v0.2.0-rc.1 -m "Release candidate"
git clone -q "$work/source" "$work/runner"
cd "$work/runner"
export SOURCE_SHA TAG_RUN_NUMBER=6 GITHUB_OUTPUT="$work/outputs"
SOURCE_SHA=$(git rev-parse HEAD)
for tag in v0.1.0 v0.2.0-rc.1; do
  : > "$GITHUB_OUTPUT"
  TAG_REF="refs/tags/$tag" SIGNAL_BRANCH="$tag" bash "$scripts/resolve-prod-tag.sh"
  grep -Fxq "version=$tag" "$GITHUB_OUTPUT"
  grep -Fxq "marker=deploy-prod-6-$SOURCE_SHA-$tag" "$GITHUB_OUTPUT"
  [[ $(wc -l < "$GITHUB_OUTPUT") -eq 2 ]]
done
if TAG_REF=refs/heads/main bash "$scripts/resolve-prod-tag.sh"; then exit 1; fi
if TAG_REF=refs/tags/v0.1.0 SIGNAL_BRANCH=v0.2.0 bash "$scripts/resolve-prod-tag.sh"; then exit 1; fi
if TAG_REF="refs/tags/v1.2.3-$(printf '%090d' 1)a" bash "$scripts/resolve-prod-tag.sh"; then exit 1; fi
git -C "$work/source" commit -qm moved --allow-empty
git -C "$work/source" tag -f v0.1.0
if TAG_REF=refs/tags/v0.1.0 bash "$scripts/resolve-prod-tag.sh"; then exit 1; fi
git -C "$work/source" branch other
git -C "$work/source" switch -q other
git -C "$work/source" commit -qm unpublished --allow-empty
git -C "$work/source" tag v2.0.0
git fetch -q origin refs/tags/v2.0.0:refs/tags/v2.0.0
if TAG_REF=refs/tags/v2.0.0 SOURCE_SHA=$(git rev-parse v2.0.0) bash "$scripts/resolve-prod-tag.sh"; then exit 1; fi
echo 'Exact release ref, protected main ancestry and fresh remote tag checks passed.'
