#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 2 || $# == 3 ]] || fail "Usage: $0 <ECR image URI> <full commit SHA> [vMAJOR.MINOR.PATCH|deploy-main-<run>-<SHA>]"
image=$1
revision=$2
tag=${3:-}
registry=${image%%/*}
repository=${image#*/}
[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com$ &&
   "$repository" == dv-ayan-kassen-1951-scholarship-applications ]] || fail "Expected the project ECR repository in us-east-1"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "Use the full lowercase Git SHA"
if [[ $# == 3 ]]; then
  number='(0|[1-9][0-9]*)'
  identifier="($number|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
  semver="^v$number\.$number\.$number(-$identifier(\.$identifier)*)?$"
  marker="^deploy-main-[1-9][0-9]*-$revision$"
  [[ ${#tag} -le 128 && ( "$tag" =~ $semver || "$tag" =~ $marker ) ]] ||
    fail "Expected a SemVer release tag or a main deployment marker for this SHA"
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export DOCKER_CONFIG="$work"
# Locally, obtain the same short-lived registry credential from the active AWS profile.
# Both clients use private files in the temporary directory, including on developer machines.
password=${ECR_PUSH_PASSWORD:-}
unset ECR_PUSH_PASSWORD
if [[ -z "$password" ]]; then
  password=$(aws ecr get-login-password --region us-east-1)
fi
printf 'AWS:%s' "$password" | base64 | tr -d '\r\n' > "$work/basic"
unset password
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$registry" "$(cat "$work/basic")" > "$work/config.json"
{ printf 'Authorization: Basic '; cat "$work/basic"; printf '\n'; } > "$work/auth.header"

api="https://$registry/v2/$repository/manifests"
accept='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'
request=(curl --proto '=https' --silent --show-error --connect-timeout 10 --max-time 60 --header "@$work/auth.header")
fetch_manifest() {
  local status
  status=$("${request[@]}" --header "Accept: $accept" --output "$2" --write-out '%{http_code}' "$api/$1") ||
    fail "ECR could not be reached"
  case $status in
    200) return 0 ;;
    404) return 1 ;;
    401|403) fail "ECR denied the manifest read for $1 (HTTP $status). Refresh the ecr-publish environment's ECR_PUSH_PASSWORD from an active Learner Lab session; verify the registry account, region and ecr:BatchGetImage permission if the retry fails." ;;
    *) fail "ECR returned HTTP $status reading the manifest for $1." ;;
  esac
}

if ! fetch_manifest "$revision" "$work/image.json"; then
  if [[ -n "$tag" ]]; then
    # A tag can arrive while the CI and publisher for its main commit are running.
    if [[ $tag == v* && ${GITHUB_ACTIONS:-} == true ]]; then
      for ((attempt=0; attempt<60; attempt++)); do
        sleep 15
        if fetch_manifest "$revision" "$work/image.json"; then break; fi
      done
    fi
    fetch_manifest "$revision" "$work/image.json" || fail "Publish the verified SHA image before promoting $tag"
  else
    built_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' campus-app:dev)
    [[ "$built_revision" == "$revision" ]] || fail "The local image revision does not match the requested commit"
    docker tag campus-app:dev "$image:$revision"
    # Another run can win the immutable tag between our lookup and push.
    if ! docker push "$image:$revision"; then
      fetch_manifest "$revision" "$work/image.json" || fail "Publishing $revision failed"
    fi
    fetch_manifest "$revision" "$work/image.json" || fail "The SHA tag could not be verified after publication"
  fi
fi

digest="sha256:$(sha256sum "$work/image.json" | cut -d ' ' -f 1)"
if [[ -n "$tag" ]]; then
  if ! fetch_manifest "$tag" "$work/tag.json"; then
    media_type=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["mediaType"])' < "$work/image.json")
    [[ ",$accept," == *",$media_type,"* ]] || fail "Unsupported ECR manifest media type"
    # Both release tags and deployment markers point at the exact SHA manifest.
    status=$("${request[@]}" --header "Content-Type: $media_type" --data-binary "@$work/image.json" \
      --request PUT --output /dev/null --write-out '%{http_code}' "$api/$tag")
    fetch_manifest "$tag" "$work/tag.json" || fail "ECR did not publish $tag (HTTP $status)"
  fi
  cmp -s "$work/image.json" "$work/tag.json" || fail "The immutable $tag tag already refers to another digest"
fi
printf 'Verified %s%s at %s\n' "$revision" "${tag:+ and $tag}" "$digest"
