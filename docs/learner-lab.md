# Deploy k3s in AWS Academy Learner Lab

This guide uses the `infra/` Terraform root to run one k3s server and one agent in `us-east-1`. The server uses `10.56.1.10` in the public subnet. The agent uses `10.56.2.10` in the private subnet. The two `t3.small` instances, their EBS volumes, public IPv4 and S3 usage count towards the lab budget.

## Start the session

1. In AWS Academy Canvas, open **Learner Lab → Modules → Launch AWS Academy Learner Lab**. Select **Start Lab** and wait for a green AWS indicator.
2. Open **AWS Details → AWS CLI**. Save the temporary credentials, including the session token, to a private file outside the checkout. The example below assumes the exported profile is named `default`. Refresh the file when the lab issues a new session.
3. Use Bash in the repository root with AWS CLI, Terraform (tested with 1.17.2), Python, `curl` and `sha256sum`. Install the helper dependency in your active Python environment with `python -m pip install boto3==1.38.0`. Terraform and the helper must use the same AWS credentials. Select the file and confirm the CLI identifies your lab account and assumed role.

```bash
export AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/css4003-learner-lab-credentials"
export AWS_PROFILE=default AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
aws iam get-instance-profile --instance-profile-name LabInstanceProfile \
  --query 'InstanceProfile.InstanceProfileName' --output text
python -c 'import boto3'
```

The lab supplies the EC2 instance profile for both nodes. Its S3 gateway endpoint policy restricts bootstrap access to the nodes in the project VPC. Only the server can publish the agent token through the endpoint. S3 uses SSE-KMS with the AWS-managed `aws/s3` key. The lab forbids the Object Lock configuration lookup performed by the AWS provider's general bucket resource. A Terraform-managed Python helper creates the dedicated bucket using basic S3 operations. Terraform configures its encryption, public access block, policy and release objects.

The current configuration also plans a private image repository and two hourly billed ECR interface endpoints. See the [registry guide](ecr.md) for costs, publishing and the private-agent pull check.

## Select the state and inputs

**For a new deployment**, choose a private directory outside the checkout. Create the input file once and keep it alongside the state. The random suffix makes the S3 name globally unique.

```bash
umask 077
LAB_DIR="$HOME/.local/share/css4003/learner-lab/us-east-1"
mkdir -p "$LAB_DIR"
STATE="$LAB_DIR/terraform.tfstate"
VARS="$LAB_DIR/learner.tfvars"
if [ ! -e "$VARS" ] && [ ! -e "$STATE" ]; then
  suffix=$(python -c 'import secrets; print(secrets.token_hex(13))')
  printf 'learner_lab = { bucket_name = "dv-ayan-kassen-1951-bootstrap-%s" }\n' "$suffix" > "$VARS"
fi
```

**For the running cluster**, point `STATE` at the absolute path of the existing `terraform.tfstate`. Initialize the checkout with `terraform -chdir=infra init -lockfile=readonly`, then read the existing bucket name with `terraform -chdir=infra output -state="$STATE" -raw bootstrap_bucket`. Set `VARS` to the absolute path of a private variables file containing `learner_lab = { bucket_name = "<existing bucket name>" }`. Run Terraform from the repository checkout and keep its state in the original private directory. An empty state would plan a second deployment.

The bucket helper defaults to `infra/bootstrap/academy_bucket.py` in this checkout and uses the active `python`. The earlier deployment recorded its helper and Python paths in `terraform_data.bootstrap_bucket`. Using the repository helper updates these paths in Terraform's bookkeeping on the next apply. To reproduce the original inputs exactly, set `learner_lab.python_executable` and `learner_lab.bucket_helper_path` to the values previously recorded. Keep the selected interpreter and helper available for teardown.

## Plan and deploy

Keep using the same `STATE` and `VARS` values. The download verifies the pinned k3s binary, bundled system images and checksum manifest. Review the saved plan before applying it. For an existing cluster, investigate any proposed node replacement first. Replacing the single server resets its local Kubernetes datastore.

```bash
bash infra/bootstrap/download.sh
terraform -chdir=infra init -lockfile=readonly
terraform -chdir=infra validate
PLAN="$(dirname "$STATE")/cluster.tfplan"
terraform -chdir=infra plan -state="$STATE" -var-file="$VARS" -out="$PLAN"
terraform -chdir=infra apply -state="$STATE" "$PLAN"
terraform -chdir=infra plan -state="$STATE" -var-file="$VARS" -detailed-exitcode
```

The final plan returns exit code `0` when Terraform finds no changes. For a new deployment, the public SSM parameter supplies the Amazon Linux 2023 AMI. Set `ami_id` in the private variables file to pin a specific regional image if you need a reproducible rebuild.

Two authenticated plans were checked against the running Learner Lab state during migration. With the original helper paths, Terraform reported **0 to add, 0 to change, 0 to destroy** and recognized the existing bucket helper at its new indexed state address. With this checkout's helper and the default Python executable, it reported **0 to add, 1 to change, 0 to destroy**. The single in-place update was to the local `terraform_data.bootstrap_bucket[0]` record. Both plans preserved every AWS resource, including both EC2 instances.

## Verify Kubernetes

Cloud-init starts k3s on each node. At first boot the server observes the Kubernetes API and writes a `CSS4003_K3S RESULT=BOTH_READY` marker when both expected internal addresses report `Ready`. The EC2 console may buffer output. To check for the marker with the AWS CLI, run:

```bash
SERVER_ID=$(terraform -chdir=infra output -state="$STATE" -json node_instance_ids | python -c 'import json,sys; print(json.load(sys.stdin)["server"])')
aws ec2 get-console-output --region us-east-1 --instance-id "$SERVER_ID" \
  --latest --query Output --output text | grep CSS4003_K3S
```

For a current result, run the following on the server through an authorized administrative connection.

```bash
sudo /usr/local/bin/k3s kubectl get nodes -o wide
```

The deployment leaves inbound SSH closed. If the serial output is stale and you use EC2 Instance Connect, temporarily allow TCP 22 on the server's ingress security group from your current public IPv4 address with a `/32` mask. Record the new security group rule ID. Send a short-lived public key for `ec2-user` with `aws ec2-instance-connect send-ssh-public-key`, verify the SSH host key against the server fingerprint from EC2 console output, and run the query. Revoke that exact rule using `aws ec2 revoke-security-group-ingress --group-id "$GROUP_ID" --security-group-rule-ids "$RULE_ID"` as soon as the query finishes, including if the connection fails.

On **22 November 2026 at 22:44 UTC**, the Kubernetes API returned the following results. The verification used a host-key-verified SSH connection restricted to the operator's IP. The temporary access rule was removed after the query. [Saved result and timestamp](evidence/k3s-ready.json)

| Role | Internal IP | Kubernetes Ready condition | Kubelet version |
|---|---|---|---|
| Server | `10.56.1.10` | `True` | `v1.37.2+k3s1` |
| Agent | `10.56.2.10` | `True` | `v1.37.2+k3s1` |

## Teardown

When the cluster is ready for removal, review a destroy plan against the same state and inputs. Applying it removes the nodes and their root volumes, including the server datastore.

```bash
DESTROY_PLAN="$(dirname "$STATE")/destroy.tfplan"
terraform -chdir=infra plan -destroy -state="$STATE" -var-file="$VARS" -out="$DESTROY_PLAN"
terraform -chdir=infra apply -state="$STATE" "$DESTROY_PLAN"
```

The helper checks ownership and project tags before deleting the dedicated bootstrap bucket. Unexpected objects or bucket versioning cause deletion to stop for review. Keep application attachments and backups in their own buckets. ECR refuses to destroy a nonempty image repository. When retiring the project, archive any images you need and remove the project's image digests before applying the final destroy plan.
