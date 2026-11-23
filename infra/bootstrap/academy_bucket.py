"""Manage the dedicated, unversioned bootstrap and backup buckets in AWS Academy."""

import os
import re
import sys

import boto3
from botocore.exceptions import ClientError


def bucket_exists(s3, target, region):
    try:
        response = s3.head_bucket(**target)
    except ClientError as error:
        if error.response["Error"]["Code"] in {"404", "NotFound", "NoSuchBucket"}:
            return False
        raise
    actual_region = response.get("BucketRegion")
    if not actual_region:
        actual_region = response["ResponseMetadata"]["HTTPHeaders"].get("x-amz-bucket-region")
    if not actual_region:
        actual_region = s3.get_bucket_location(**target)["LocationConstraint"] or "us-east-1"
    if actual_region != region:
        raise RuntimeError("The bucket is outside the expected region")
    return True


def read_tags(s3, target):
    try:
        entries = s3.get_bucket_tagging(**target)["TagSet"]
    except ClientError as error:
        if error.response["Error"]["Code"] == "NoSuchTagSet":
            return {}
        raise
    return {tag["Key"]: tag["Value"] for tag in entries}


def manage(action, session, name, owner, region, project, purpose="bootstrap"):
    if action not in {"ensure", "destroy"}:
        raise ValueError("Expected ensure or destroy")
    if (
        not project
        or purpose not in {"bootstrap", "backups"}
        or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", name)
    ):
        raise ValueError("Invalid project, purpose or bucket name")
    if not name.startswith(f"{project}-{purpose}-"):
        raise ValueError("The bucket name is outside its project namespace")
    if not re.fullmatch(r"[0-9]{12}", owner):
        raise ValueError("Expected the AWS account ID of LabInstanceProfile")
    if session.client("sts", region_name=region).get_caller_identity()["Account"] != owner:
        raise RuntimeError("The current AWS account differs from the instance profile owner")

    s3 = session.client("s3", region_name=region)
    target = {"Bucket": name, "ExpectedBucketOwner": owner}
    exists = bucket_exists(s3, target, region)
    expected = {"Name": f"{project}-{purpose}", "Project": project, "ManagedBy": "Terraform"}
    tags = read_tags(s3, target) if exists else {}
    owned = all(tags.get(key) == value for key, value in expected.items())

    if action == "ensure":
        if owned:
            return
        if exists:
            # A previous run can stop after CreateBucket and before tagging.
            if (
                tags
                or s3.get_bucket_versioning(**target).get("Status")
                or s3.list_objects_v2(**target, MaxKeys=1).get("Contents")
                or s3.list_multipart_uploads(**target, MaxUploads=1).get("Uploads")
            ):
                raise RuntimeError("Refusing to adopt a bucket with other tags, versions, objects or uploads")
        else:
            arguments = {"Bucket": name}
            if region != "us-east-1":
                arguments["CreateBucketConfiguration"] = {"LocationConstraint": region}
            s3.create_bucket(**arguments)
            if not bucket_exists(s3, target, region):
                raise RuntimeError("Unable to confirm the new bucket's owner and region")
            if read_tags(s3, target):
                raise RuntimeError("The newly created bucket already has tags; retry to verify its identity")
        s3.put_bucket_tagging(
            **target, Tagging={"TagSet": [{"Key": key, "Value": value} for key, value in expected.items()]}
        )
        return

    if not exists:
        return
    if not owned:
        raise RuntimeError("The existing bucket lacks matching Name, Project and ManagedBy ownership tags")
    if s3.get_bucket_versioning(**target).get("Status"):
        raise RuntimeError("Refusing to delete a versioned or previously versioned bucket")
    contents = s3.list_objects_v2(**target, MaxKeys=2)
    keys = [item["Key"] for item in contents.get("Contents", [])]
    disposable_keys = {"cluster/agent-token"} if purpose == "bootstrap" else set()
    if contents.get("IsTruncated") or not set(keys).issubset(disposable_keys):
        raise RuntimeError(f"Unexpected objects remain in the {purpose} bucket")
    if s3.list_multipart_uploads(**target, MaxUploads=1).get("Uploads"):
        raise RuntimeError(f"Unfinished multipart uploads remain in the {purpose} bucket")
    if keys:
        s3.delete_object(**target, Key="cluster/agent-token")
    # S3 also refuses deletion if another object arrives after listing.
    s3.delete_bucket(**target)


if __name__ == "__main__":
    manage(
        sys.argv[1],
        boto3.Session(),
        os.environ["ACADEMY_BUCKET"],
        os.environ["ACADEMY_OWNER"],
        os.environ["ACADEMY_REGION"],
        os.environ["ACADEMY_PROJECT"],
        os.environ.get("ACADEMY_PURPOSE", "bootstrap"),
    )
