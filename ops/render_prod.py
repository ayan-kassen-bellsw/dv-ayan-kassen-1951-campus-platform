"""Build the initial, scaled-to-zero prod Deployment from the reviewed application spec."""

import json
import re
import sys
from pathlib import Path

PROJECT = "dv-ayan-kassen-1951"
LABEL = "app.kubernetes.io/name"
PROD = "scholarship-applications-prod"


def main():
    baseline = json.load(sys.stdin)
    source = json.loads(Path(sys.argv[1]).read_text())
    source_pod = source["spec"]["template"]["spec"]
    source_app = next(c for c in source_pod["containers"] if c["name"] == "app")
    if source_app["image"] != sys.argv[2]:
        raise ValueError("The main image changed during bootstrap; retry with the current image")
    (config,) = [ref["configMapRef"]["name"] for ref in source_app["envFrom"] if "configMapRef" in ref]
    if not re.fullmatch(PROJECT + r"-app-config-[a-z0-9]{10}", config):
        raise ValueError("Expected the project's generated app ConfigMap")

    baseline["metadata"] = {"name": PROJECT + "-prod", "namespace": PROJECT}
    baseline.pop("status", None)
    spec = baseline["spec"]
    spec["replicas"] = 0
    spec["selector"]["matchLabels"][LABEL] = PROD
    template = spec["template"]
    template["metadata"]["labels"][LABEL] = PROD
    pod = template["spec"]
    for constraint in pod["topologySpreadConstraints"]:
        constraint["labelSelector"]["matchLabels"][LABEL] = PROD
    app = next(c for c in pod["containers"] if c["name"] == "app")
    app["image"] = source_app["image"]
    app["imagePullPolicy"] = source_app["imagePullPolicy"]
    app["envFrom"] = [{"configMapRef": {"name": config}}]
    if {"name": PROJECT + "-ecr-pull"} in source_pod.get("imagePullSecrets", []):
        pod["imagePullSecrets"] = [{"name": PROJECT + "-ecr-pull"}]
    json.dump(baseline, sys.stdout)


if __name__ == "__main__":
    main()
