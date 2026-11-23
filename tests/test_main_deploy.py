import json
from threading import Barrier
from unittest.mock import Mock, call

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


def test_prod_requires_the_approved_marker_sha_and_semver_at_one_digest():
    version = "v1.0.0-rc.2"
    prod = f"deploy-prod-18-{SHA}-{version}"
    entries = [tag(SHA), tag(version), tag(f"deploy-main-100-{SHA}")]
    for invalid in ("v0.01.0", "v1.0.0-00", "v1.0.0+build", "v1", "v1.0.0-" + "x" * 80):
        entries.append(tag(f"deploy-prod-99-{SHA}-{invalid}"))
    assert cd.latest_release(entries, "prod") is None
    entries.append(tag(prod))
    assert cd.latest_release(entries, "prod") == {"number": 18, "sha": SHA, "digest": DIGEST, "version": version}
    for inconsistent in (
        [tag(f"deploy-prod-19-{SHA}-v2.0.0")],
        [tag("v2.0.0", "sha256:" + "e" * 64), tag(f"deploy-prod-19-{SHA}-v2.0.0")],
        [tag("v2.0.0"), tag(f"deploy-prod-19-{'a' * 40}-v2.0.0")],
        [tag("v2.0.0"), tag(f"deploy-prod-18-{SHA}-v2.0.0")],
    ):
        with pytest.raises(ValueError):
            cd.latest_release(entries + inconsistent, "prod")


@pytest.mark.parametrize("starting_replicas", [0, 3])
def test_prod_activation_patches_only_prod_and_probes_its_host(monkeypatch, tmp_path, starting_replicas):
    version = "v0.2.0"
    release = {"number": 1, "sha": SHA, "digest": DIGEST, "version": version}
    checkpoint = tmp_path / "prod-applied.json"
    token = tmp_path / "token"
    token.write_text("ephemeral-identity")
    current = {"spec": {"replicas": starting_replicas}, "metadata": {"resourceVersion": "99"}}
    replicas = starting_replicas or 2
    rolled = {
        "spec": {"replicas": replicas, "template": {"spec": {"containers": [{"name": "app", "image": IMAGE}]}}},
        "metadata": {"generation": 5},
        "status": dict.fromkeys(("updatedReplicas", "readyReplicas", "availableReplicas", "replicas"), replicas)
        | {"observedGeneration": 5},
    }
    api = Mock(side_effect=[current, {}, rolled, rolled])
    ingress = Mock(
        side_effect=[
            {"hostname": cd.APP + "-outside-prod", "git_sha": SHA, "version": version},
            {"hostname": cd.PROD_APP + "-prod-pod", "git_sha": SHA, "version": version},
            {"ready": True},
        ]
    )
    monkeypatch.setattr(cd, "api", api)
    monkeypatch.setattr(cd, "ingress", ingress)
    monkeypatch.setattr(cd, "Path", lambda p: token)
    monkeypatch.setattr(cd.ssl, "create_default_context", Mock())
    monkeypatch.setattr(cd.time, "sleep", Mock())

    cd.deploy(release, REGISTRY, checkpoint, "prod")
    assert all(c.kwargs["app"] == cd.PROD_APP for c in api.call_args_list)
    patch = api.call_args_list[1].args[3]
    if starting_replicas == 0:
        assert patch["spec"]["replicas"] == 2
        assert patch["metadata"]["resourceVersion"] == "99"
    else:
        assert "replicas" not in patch["spec"]
    container = patch["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == IMAGE
    assert {v["name"]: v["value"] for v in container["env"]} == {"GIT_SHA": SHA, "APP_VERSION": version}
    assert ingress.call_args_list == [call("/info", cd.PROD_HOST)] * 2 + [call("/readyz", cd.PROD_HOST)]
    assert json.loads(checkpoint.read_text()) == release
    api.reset_mock()
    cd.deploy(release, REGISTRY, checkpoint, "prod")
    api.assert_not_called()


@pytest.mark.parametrize("broken", ["main", "prod"])
def test_independent_rollouts_finish_even_if_other_environment_fails(monkeypatch, tmp_path, broken):
    entries = [tag(SHA), tag("v1.0.0"), tag(f"deploy-main-26-{SHA}"), tag(f"deploy-prod-3-{SHA}-v1.0.0")]
    both_running = Barrier(2)

    def rollout(release, registry, checkpoint, environment):
        both_running.wait(timeout=5)
        if environment == broken:
            raise RuntimeError("rollout failed")
        checkpoint.write_text(str(release["number"]))

    monkeypatch.setattr(cd, "deploy", rollout)
    with pytest.raises(RuntimeError, match=f"{broken}: rollout failed"):
        cd.reconcile(entries, REGISTRY, tmp_path)
    name, number = ("applied.json", "26") if broken == "prod" else ("prod-applied.json", "3")
    assert (tmp_path / name).read_text() == number
