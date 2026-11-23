from unittest.mock import Mock

import pytest

from infra.bootstrap.academy_bucket import manage

OWNER = "123456789012"
REGION = "us-east-1"
PROJECT = "test-project"
BUCKET = f"{PROJECT}-bootstrap-example"
TARGET = {"Bucket": BUCKET, "ExpectedBucketOwner": OWNER}
TAGS = [
    {"Key": "Project", "Value": PROJECT},
    {"Key": "Name", "Value": f"{PROJECT}-bootstrap"},
    {"Key": "ManagedBy", "Value": "Terraform"},
]


@pytest.fixture
def clients():
    sts = Mock()
    sts.get_caller_identity.return_value = {"Account": OWNER}
    s3 = Mock()
    s3.head_bucket.return_value = {"BucketRegion": REGION}
    s3.get_bucket_tagging.return_value = {"TagSet": []}
    s3.get_bucket_versioning.return_value = {}
    s3.list_objects_v2.return_value = {}
    s3.list_multipart_uploads.return_value = {}
    session = Mock()
    session.client.side_effect = lambda service, region_name: {"sts": sts, "s3": s3}[service]
    return session, s3


def test_resume_tagging_empty_bucket(clients):
    session, s3 = clients
    manage("ensure", session, BUCKET, OWNER, REGION, PROJECT)
    s3.create_bucket.assert_not_called()
    s3.list_objects_v2.assert_called_once_with(**TARGET, MaxKeys=1)
    s3.list_multipart_uploads.assert_called_once_with(**TARGET, MaxUploads=1)
    tags = s3.put_bucket_tagging.call_args.kwargs["Tagging"]["TagSet"]
    assert sorted(tags, key=lambda tag: tag["Key"]) == sorted(TAGS, key=lambda tag: tag["Key"])


@pytest.mark.parametrize(
    ("operation", "response"),
    [
        ("get_bucket_tagging", {"TagSet": [{"Key": "Project", "Value": "other"}]}),
        ("get_bucket_versioning", {"Status": "Suspended"}),
        ("list_objects_v2", {"Contents": [{"Key": "other-object"}]}),
        ("list_multipart_uploads", {"Uploads": [{"Key": "unfinished"}]}),
    ],
)
def test_refuse_adoption_of_existing_data_or_tags(clients, operation, response):
    session, s3 = clients
    getattr(s3, operation).return_value = response
    with pytest.raises(RuntimeError, match="Refusing to adopt"):
        manage("ensure", session, BUCKET, OWNER, REGION, PROJECT)
    s3.put_bucket_tagging.assert_not_called()


@pytest.mark.parametrize(
    ("operation", "response"),
    [
        ("get_bucket_tagging", {"TagSet": []}),
        ("get_bucket_versioning", {"Status": "Enabled"}),
        ("list_objects_v2", {"Contents": [{"Key": "cluster/agent-token"}, {"Key": "user-data"}]}),
        ("list_multipart_uploads", {"Uploads": [{"Key": "unfinished"}]}),
    ],
)
def test_destroy_preserves_bucket_with_unexpected_contents_or_ownership(clients, operation, response):
    session, s3 = clients
    s3.get_bucket_tagging.return_value = {"TagSet": TAGS}
    getattr(s3, operation).return_value = response
    with pytest.raises(RuntimeError):
        manage("destroy", session, BUCKET, OWNER, REGION, PROJECT)
    s3.delete_object.assert_not_called()
    s3.delete_bucket.assert_not_called()


def test_destroy_removes_only_the_runtime_token(clients):
    session, s3 = clients
    s3.get_bucket_tagging.return_value = {"TagSet": TAGS}
    s3.list_objects_v2.return_value = {"Contents": [{"Key": "cluster/agent-token"}]}
    manage("destroy", session, BUCKET, OWNER, REGION, PROJECT)
    s3.delete_object.assert_called_once_with(**TARGET, Key="cluster/agent-token")
    s3.delete_bucket.assert_called_once_with(**TARGET)


@pytest.mark.parametrize("key", ["postgresql/campus-20261123.dump", "cluster/agent-token"])
def test_backup_helper_never_deletes_objects(clients, key):
    session, s3 = clients
    name = f"{PROJECT}-backups-example"
    s3.get_bucket_tagging.return_value = {
        "TagSet": [tag if tag["Key"] != "Name" else {"Key": "Name", "Value": f"{PROJECT}-backups"} for tag in TAGS]
    }
    s3.list_objects_v2.return_value = {"Contents": [{"Key": key}]}
    with pytest.raises(RuntimeError, match="objects remain"):
        manage("destroy", session, name, OWNER, REGION, PROJECT, purpose="backups")
    s3.delete_object.assert_not_called()
    s3.delete_bucket.assert_not_called()
