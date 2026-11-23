"""Reconcile independent main and approved prod deployments from immutable ECR tags."""

import http.client
import json
import os
import re
import ssl
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PROJECT = "dv-ayan-kassen-1951"
UNIT = f"{PROJECT}-main-deploy"
APP = f"{PROJECT}-app"
PROD_APP = f"{PROJECT}-prod"
PROD_HOST = "prod.scholarships.test"
REPO = f"{PROJECT}-scholarship-applications"
NUMBER = r"(?:0|[1-9][0-9]*)"
PRERELEASE_ID = rf"(?:{NUMBER}|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = rf"v{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{PRERELEASE_ID}(?:\.{PRERELEASE_ID})*)?"
RUN_SHA = r"(?P<number>[1-9][0-9]*)-(?P<sha>[a-f0-9]{40})"
MARKERS = {
    "main": re.compile(rf"deploy-main-{RUN_SHA}"),
    "prod": re.compile(rf"deploy-prod-{RUN_SHA}-(?P<version>{SEMVER})"),
}
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")


def latest_release(images, environment="main"):
    tags = {image["imageTag"]: image["imageDigest"] for image in images}
    pattern = MARKERS[environment]
    markers = [m for tag in tags if len(tag) <= 128 and (m := pattern.fullmatch(tag))]
    if not markers:
        return None
    latest = max(markers, key=lambda m: int(m["number"]))
    if sum(m["number"] == latest["number"] for m in markers) != 1:
        raise ValueError(f"Conflicting {environment} markers for the same CI run number")
    sha = latest["sha"]
    digest = tags[latest[0]]
    if not DIGEST.fullmatch(digest) or tags.get(sha) != digest:
        raise ValueError(f"The {environment} marker and immutable Git SHA do not identify the same image")
    release = {"number": int(latest["number"]), "sha": sha, "digest": digest}
    if environment == "prod":
        version = latest["version"]
        if tags.get(version) != digest:
            raise ValueError("Prod marker and immutable SemVer tag do not identify the same image")
        release["version"] = version
    return release


def api(method, token, ca, patch=None, *, app=APP):
    # Fixed loopback origin. Never forward a service account credential across a redirect.
    conn = http.client.HTTPSConnection("127.0.0.1", 6443, timeout=10, context=ca)
    headers = {"Authorization": f"Bearer {token}"}
    if patch:
        headers["Content-Type"] = "application/strategic-merge-patch+json"
    try:
        path = f"/apis/apps/v1/namespaces/{PROJECT}/deployments/{app}"
        conn.request(method, path, body=json.dumps(patch) if patch else None, headers=headers)
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Kubernetes {method} for {app} returned HTTP {response.status}")
        return json.load(response)
    finally:
        conn.close()


def ingress(path, host=None):
    conn = http.client.HTTPConnection("127.0.0.1", 80, timeout=5)
    try:
        conn.request("GET", path, headers={"Host": host} if host else {})
        response = conn.getresponse()
        return json.load(response) if response.status == 200 else {}
    finally:
        conn.close()


def rolled_out(obj, image):
    replicas = obj["spec"]["replicas"]
    status = obj.get("status", {})
    containers = obj["spec"]["template"]["spec"]["containers"]
    app = next(c for c in containers if c["name"] == "app")
    return (
        app["image"] == image
        and status.get("observedGeneration", 0) >= obj["metadata"]["generation"]
        and replicas >= 2
        and all(
            status.get(field, 0) == replicas
            for field in ("replicas", "readyReplicas", "updatedReplicas", "availableReplicas")
        )
    )


def deploy(release, registry, checkpoint, environment="main"):
    if checkpoint.exists():
        previous = json.loads(checkpoint.read_text())
        if previous["number"] == release["number"] and previous != release:
            raise ValueError("An already applied release marker changed")
        if previous["number"] >= release["number"]:
            return  # An operator can roll back without the next poll immediately undoing it.

    ca = ssl.create_default_context(cafile=f"/etc/{UNIT}/ca.crt")
    token = Path(f"/run/{UNIT}-credentials/token").read_text().strip()
    sha = release["sha"]
    prod = environment == "prod"
    app = PROD_APP if prod else APP
    host = PROD_HOST if prod else None
    version = release["version"] if prod else f"main-{release['number']}"
    image = f"{registry}/{REPO}@{release['digest']}"
    container = {
        "name": "app",
        "image": image,
        "env": [{"name": "GIT_SHA", "value": sha}, {"name": "APP_VERSION", "value": version}],
    }
    patch = {"spec": {"template": {"spec": {"containers": [container]}}}}
    if prod:
        current = api("GET", token, ca, app=app)
        if current["spec"]["replicas"] == 0:
            # Activate prod on approval. Preserve an existing replica count on later releases.
            patch["metadata"] = {"resourceVersion": current["metadata"]["resourceVersion"]}
            patch["spec"]["replicas"] = 2
    api("PATCH", token, ca, patch, app=app)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if rolled_out(api("GET", token, ca, app=app), image):
            try:
                info = ingress("/info", host)
                correct_pod = not prod or info.get("hostname", "").startswith(f"{PROD_APP}-")
                if (
                    correct_pod
                    and info.get("git_sha") == sha
                    and info.get("version") == version
                    and ingress("/readyz", host).get("ready")
                ):
                    pending = checkpoint.with_suffix(".tmp")
                    pending.write_text(json.dumps(release) + "\n")
                    pending.replace(checkpoint)
                    print(f"Deployed {sha} at {release['digest']} ({version})")
                    return
            except (OSError, http.client.HTTPException, ValueError):
                pass  # Endpoints can change while Traefik processes the rollout.
        time.sleep(3)
    raise RuntimeError(f"Deployment or ingress failed to confirm {sha} within five minutes")


def reconcile(images, registry, state):
    def reconcile_environment(environment, checkpoint):
        release = latest_release(images, environment)
        if release:
            deploy(release, registry, checkpoint, environment)

    # Each rollout may take five minutes; both share a ten-minute service account token.
    checkpoints = {"main": state / "applied.json", "prod": state / "prod-applied.json"}
    errors = []
    with ThreadPoolExecutor(max_workers=len(checkpoints)) as pool:
        tasks = {env: pool.submit(reconcile_environment, env, path) for env, path in checkpoints.items()}
        for env, task in tasks.items():
            try:
                task.result()
            except Exception as error:
                errors.append(f"{env}: {error}")
    if errors:
        raise RuntimeError("; ".join(errors))


def main():
    import fcntl  # The service runs on Linux. The release selection is also tested on Windows.

    registry = os.environ["ECR_REGISTRY"]
    if not re.fullmatch(r"[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com", registry):
        raise ValueError("Expected the project ECR registry hostname in us-east-1")
    state = Path(os.environ["STATE_DIRECTORY"])
    with (state / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reconcile(json.load(sys.stdin)["imageIds"], registry, state)


if __name__ == "__main__":
    main()
