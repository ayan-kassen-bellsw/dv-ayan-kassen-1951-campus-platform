import json
from unittest.mock import Mock

import pytest

from ops import reconcile_main as cd

SHA = "b" * 40
DIGEST = "sha256:" + "d" * 64
REGISTRY = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
IMAGE = f"{REGISTRY}/{cd.REPO}@{DIGEST}"


def tag(name, digest=DIGEST):
    return {"imageTag": name, "imageDigest": digest}


def test_only_main_markers_select_the_latest_run_number():
    entries = [tag(SHA), tag("v0.1.0"), tag(f"deploy-main-010-{SHA}")]
    assert cd.latest_release(entries) is None
    entries.extend([tag(f"deploy-main-9-{SHA}"), tag(f"deploy-main-10-{SHA}")])
    assert cd.latest_release(entries) == {"number": 10, "sha": SHA, "digest": DIGEST}


def test_conflicting_markers_or_missing_sha_are_rejected():
    marker = tag(f"deploy-main-10-{SHA}")
    with pytest.raises(ValueError, match="same CI run number"):
        cd.latest_release([tag(SHA), marker, tag("deploy-main-10-" + "f" * 40)])
    for tags in ([marker], [marker, tag(SHA, "sha256:" + "e" * 64)]):
        with pytest.raises(ValueError, match="same image"):
            cd.latest_release(tags)


def test_confirmed_release_is_applied_once_and_respects_rollback(monkeypatch, tmp_path):
    release = {"number": 10, "sha": SHA, "digest": DIGEST}
    deployment = {
        "metadata": {"generation": 4},
        "spec": {"replicas": 2, "template": {"spec": {"containers": [{"name": "app", "image": IMAGE}]}}},
        "status": {
            "observedGeneration": 4,
            "replicas": 2,
            "readyReplicas": 2,
            "updatedReplicas": 2,
            "availableReplicas": 2,
        },
    }
    api = Mock(return_value=deployment)
    monkeypatch.setattr(cd, "api", api)
    monkeypatch.setattr(cd, "ingress", Mock(side_effect=[{"git_sha": SHA, "version": "main-10"}, {"ready": True}]))
    monkeypatch.setattr(cd.ssl, "create_default_context", Mock())
    token = tmp_path / "token"
    token.write_text("ephemeral-identity")
    monkeypatch.setattr(cd, "Path", lambda p: token)
    checkpoint = tmp_path / "applied.json"
    cd.deploy(release, REGISTRY, checkpoint)
    patch = api.call_args_list[0].args[3]
    assert patch == {
        "spec": {
            "template": {
                "spec": {
                    "containers": [
                        {
                            "name": "app",
                            "image": IMAGE,
                            "env": [{"name": "GIT_SHA", "value": SHA}, {"name": "APP_VERSION", "value": "main-10"}],
                        }
                    ]
                }
            }
        }
    }
    assert json.loads(checkpoint.read_text()) == release
    api.reset_mock()
    cd.deploy(release, REGISTRY, checkpoint)
    cd.deploy(dict(release, number=9), REGISTRY, checkpoint)
    api.assert_not_called()
    with pytest.raises(ValueError, match="already applied"):
        cd.deploy(dict(release, sha="e" * 40), REGISTRY, checkpoint)
    deployment["status"]["updatedReplicas"] = 1
    assert not cd.rolled_out(deployment, IMAGE)
