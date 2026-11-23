#!/usr/bin/env bash
set -euo pipefail

: "${TAG_REF:?Expected the full ref from the tag signal}" "${SOURCE_SHA:?}" "${TAG_RUN_NUMBER:?}"
version=${TAG_REF#refs/tags/}
number='(0|[1-9][0-9]*)'
identifier="($number|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
semver="^v$number\.$number\.$number(-$identifier(\.$identifier)*)?$"
marker="deploy-prod-$TAG_RUN_NUMBER-$SOURCE_SHA-$version"
[[ $SOURCE_SHA =~ ^[a-f0-9]{40}$ && $TAG_RUN_NUMBER =~ ^[1-9][0-9]*$ &&
   $TAG_REF == refs/tags/* && $version =~ $semver && ${#marker} -le 128 ]] ||
  { echo 'Invalid release tag, commit or marker length' >&2; exit 2; }
case ${SIGNAL_BRANCH:-} in
  refs/tags/*|v[0-9]*) [[ ${SIGNAL_BRANCH#refs/tags/} == "$version" ]] ||
    { echo 'The signal ref and tag disagree' >&2; exit 1; } ;;
esac
[[ $(git rev-parse --verify "$TAG_REF^{commit}") == "$SOURCE_SHA" ]]
git merge-base --is-ancestor "$SOURCE_SHA" HEAD
# A force-moved/deleted tag must also fail if the runner still has an old checkout.
remote=$(git ls-remote --exit-code origin "$TAG_REF" "$TAG_REF^{}")
commit=$(awk -v ref="$TAG_REF" '$2 == ref {tag=$1} $2 == ref "^{}" {peeled=$1} END {print peeled ? peeled : tag}' <<< "$remote")
[[ $commit == "$SOURCE_SHA" ]] || { echo 'Remote release tag changed' >&2; exit 1; }
printf 'version=%s\nmarker=%s\n' "$version" "$marker" >> "${GITHUB_OUTPUT:?}"
