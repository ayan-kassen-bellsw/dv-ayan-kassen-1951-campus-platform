"""Deploy the latest protected-main marker discovered in the project's immutable ECR repository."""

import http.client
import json
import os
import re
import ssl
import sys
import time
from pathlib import Path

PROJECT = "dv-ayan-kassen-1951"
UNIT = f"{PROJECT}-main-deploy"
APP = f"{PROJECT}-app"
DEPLOYMENT = f"/apis/apps/v1/namespaces/{PROJECT}/deployments/{APP}"
REPO = f"{PROJECT}-scholarship-applications"
MARKER = re.compile(r"deploy-main-([1-9][0-9]*)-([a-f0-9]{40})")
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")


def latest_release(images):
    tags = {image["imageTag"]: image["imageDigest"] for image in images}
    markers = [(int(m[1]), m[2], digest) for tag, digest in tags.items() if (m := MARKER.fullmatch(tag))]
    if not markers:
        return None
    number, sha, digest = max(markers)
    if sum(m[0] == number for m in markers) != 1:
        raise ValueError("Conflicting main markers for the same CI run number")
    if not DIGEST.fullmatch(digest) or tags.get(sha) != digest:
        raise ValueError("Main marker and immutable Git SHA do not identify the same image")
    return {"number": number, "sha": sha, "digest": digest}


def api(method, token, ca, patch=None):
    # Fixed loopback origin. Never forward a service account credential across a redirect.
    conn = http.client.HTTPSConnection("127.0.0.1", 6443, timeout=10, context=ca)
    headers = {"Authorization": f"Bearer {token}"}
    if patch:
        headers["Content-Type"] = "application/strategic-merge-patch+json"
    try:
        conn.request(method, DEPLOYMENT, body=json.dumps(patch) if patch else None, headers=headers)
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Kubernetes {method} for {APP} returned HTTP {response.status}")
        return json.load(response)
    finally:
        conn.close()


def ingress(path):
    conn = http.client.HTTPConnection("127.0.0.1", 80, timeout=5)
    try:
        conn.request("GET", path)
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


def deploy(release, registry, checkpoint):
    if checkpoint.exists():
        previous = json.loads(checkpoint.read_text())
        if previous["number"] == release["number"] and previous != release:
            raise ValueError("An already applied release marker changed")
        if previous["number"] >= release["number"]:
            return  # An operator can roll back without the next poll immediately undoing it.

    ca = ssl.create_default_context(cafile=f"/etc/{UNIT}/ca.crt")
    token = Path(f"/run/{UNIT}-credentials/token").read_text().strip()
    sha = release["sha"]
    version = f"main-{release['number']}"
    image = f"{registry}/{REPO}@{release['digest']}"
    container = {
        "name": "app",
        "image": image,
        "env": [{"name": "GIT_SHA", "value": sha}, {"name": "APP_VERSION", "value": version}],
    }
    api("PATCH", token, ca, {"spec": {"template": {"spec": {"containers": [container]}}}})
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if rolled_out(api("GET", token, ca), image):
            try:
                info = ingress("/info")
                if info.get("git_sha") == sha and info.get("version") == version and ingress("/readyz").get("ready"):
                    pending = checkpoint.with_suffix(".tmp")
                    pending.write_text(json.dumps(release) + "\n")
                    pending.replace(checkpoint)
                    print(f"Deployed {sha} at {release['digest']} ({version})")
                    return
            except (OSError, http.client.HTTPException, ValueError):
                pass  # Endpoints can change while Traefik processes the rollout.
        time.sleep(3)
    raise RuntimeError(f"Deployment or ingress failed to confirm {sha} within five minutes")


def main():
    import fcntl  # The service runs on Linux. The release selection is also tested on Windows.

    registry = os.environ["ECR_REGISTRY"]
    if not re.fullmatch(r"[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com", registry):
        raise ValueError("Expected the project ECR registry hostname in us-east-1")
    state = Path(os.environ["STATE_DIRECTORY"])
    with (state / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        release = latest_release(json.load(sys.stdin)["imageIds"])
        if release:
            deploy(release, registry, state / "applied.json")


if __name__ == "__main__":
    main()
