# Publish and verify the scholarship application image

Terraform defines the private repository `dv-ayan-kassen-1951-scholarship-applications` in `us-east-1`. Image tags are immutable. ECR scans images on push and encrypts them with its AWS-managed KMS key. The registry API and Docker endpoints each use one network interface in the private subnet. Only the cluster security group can connect over HTTPS. Both nodes can download image layers through the existing regional S3 gateway. [ECR private connectivity](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)

The Learner Lab apply created six resources and updated the S3 gateway endpoint policy in place. The following plan returned exit code 0. The private agent pulled and executed the published `v0.1.0` image by digest. [Live pull result](evidence/ecr-private-agent.txt)

The two interfaces together cost about **$0.02/hour** in one availability zone, plus data processing and ECR storage. [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)

## Enable publishing after provisioning

1. Use the [Learner Lab guide](learner-lab.md) with its existing state. After applying the reviewed plan, `terraform -chdir=infra output -state="$STATE" -raw ecr_repository_url` returns the image URI.
2. In GitHub, configure the `ecr-publish` environment to allow deployments from the **branch `main` only**. The repository variable `ECR_REGISTRY` contains the hostname portion of the image URI. The environment secret `ECR_PUSH_PASSWORD` contains the expiring Docker password. Renew it from an active lab session and an authenticated GitHub CLI with the following command in the checkout.

   ```bash
   bash ops/refresh-ecr-publisher.sh
   ```

3. Set `ECR_PUBLISH_ENABLED=true` and set `K3S_APP_URL` to the public Ingress origin in repository variables. Update the URL if the server's public address changes. Install the deployment service on the k3s server using the steps below. On a push to `main`, CI tests the image in Compose and k3s, scans it with Trivy and saves the tested artifact for one day. **Publish ECR** pushes the artifact under the full commit SHA. When that SHA is still the tip of `main`, the publisher signals the cluster and verifies the rollout through Ingress.
4. Push a semver Git tag such as `v0.2.0` at a published commit on `main`. The tag signals the publisher on the default branch. It verifies the commit and attaches the version tag to the existing image manifest so both tags resolve to the same digest. For tags that predate this workflow, build the exact tagged checkout as `campus-app:dev` with the full commit in the OCI revision label, run the Compose and Trivy checks, then use the publication script from the current checkout.

   ```bash
   IMAGE=$(terraform -chdir=infra output -state="$STATE" -raw ecr_repository_url)
   SHA=$(git rev-parse 'v0.1.0^{commit}')
   bash .github/scripts/publish-ecr.sh "$IMAGE" "$SHA"
   bash .github/scripts/publish-ecr.sh "$IMAGE" "$SHA" v0.1.0
   ```

## Verify on the private agent

From the workstation, retrieve the digest for an actual published commit and check the tags. Then run the probe on the server through an authorized administration connection, passing the resulting `IMAGE@DIGEST` argument. The server needs its instance profile, AWS CLI, Bash, Python 3 and access to the local k3s API.

```bash
REPO=dv-ayan-kassen-1951-scholarship-applications
DIGEST=$(aws ecr describe-images --region us-east-1 --repository-name "$REPO" \
  --image-ids "imageTag=$SHA" --query 'imageDetails[0].imageDigest' --output text)
aws ecr describe-images --region us-east-1 --repository-name "$REPO" \
  --image-ids "imageDigest=$DIGEST" --query 'imageDetails[0].imageTags'
# SERVER is the configured SSH destination with a verified host key.
ssh "$SERVER" "sudo bash -s -- '$IMAGE@$DIGEST'" < ops/verify-ecr-pull.sh
```

The probe schedules a disposable Pod on the Ready agent at `10.56.2.10`, requests a fresh registry pull, checks the container's image ID and executes Python as UID 10001. It removes its namespace and temporary registry secret on exit. Save the success line with its timestamp and digest as evidence after the first live run.

## Deploy images from main

Apply the ECR endpoint policy in Terraform. It lets the k3s server list tags in the project repository through the private ECR API endpoint. On a server with the application already deployed, run the installer from the checkout, using the registry hostname from the Terraform `ecr_repository_url` output.

```bash
sudo bash ops/install-main-deployer.sh "${ECR_REGISTRY:?Set the registry hostname}"
systemctl is-enabled dv-ayan-kassen-1951-main-deploy.timer
sudo journalctl -u dv-ayan-kassen-1951-main-deploy.service -n 20 --no-pager
```

After CI passes on `main`, the publisher adds an immutable `deploy-main-<CI run number>-<full SHA>` tag to the tested image. The server checks ECR every 30 seconds and matches the newest numbered tag to the commit's digest. Its service account can read and patch the named application Deployment. It updates the image, `GIT_SHA` and `APP_VERSION` together, waits for ready replicas, then records the release in `/var/lib/dv-ayan-kassen-1951-main-deploy/applied.json`. GitHub checks `/readyz` and reads the SHA from two different replicas through the public `/info` endpoint. GitHub runners reach the public application over HTTP(S); cluster administration runs on the server.

The timer handles image releases. Apply changes to Services, Ingress or application manifests with the deployment script; reinstall the host files when upgrading the service itself. To roll back a confirmed release, use the command below. The server's saved run number preserves that rollback until the next numbered deployment. If a rollout failed before confirmation, stop the timer while investigating and rolling back, then resume it after publishing a corrected release. [Application deployment guide](k3s-app.md)

```bash
sudo /usr/local/bin/k3s kubectl -n dv-ayan-kassen-1951 rollout undo deployment/dv-ayan-kassen-1951-app
```

## Recover a failed ECR publication

An HTTP 401 or 403 on a manifest request means the registry rejected that request. From an active Learner Lab session, run `bash ops/refresh-ecr-publisher.sh`. It compares the AWS repository with the GitHub registry setting, reads the published `v0.1.0` manifest with the new password and updates the encrypted `ecr-publish` environment secret. ECR issues passwords for up to 12 hours. Renew the credential when starting a new lab session or when the publisher reports an authorization failure. [AWS registry authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)

Rerun the failed **Publish ECR** job while the source CI artifact is available. If the artifact has expired, rerun the source `main` CI to rebuild and retest it. A persistent 403 with a fresh credential warrants checking the registry account and the active role's ECR read and push permissions. [Successful retry for 9c3af99](https://github.com/ayan-kassen-bellsw/dv-ayan-kassen-1951-campus-platform/actions/runs/45123891483/attempts/2)

For the first live check, the operator ran the workflow's marker step for the already merged commit `9c3af99` after its successful publication. The server deployed that digest and both replicas returned version `main-24` through Ingress. [Learner Lab deployment evidence](evidence/main-cd.json)
