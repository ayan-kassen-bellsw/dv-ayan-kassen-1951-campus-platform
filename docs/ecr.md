# Publish and verify the scholarship application image

Terraform defines the private repository `dv-ayan-kassen-1951-scholarship-applications` in `us-east-1`. Image tags are immutable. ECR scans images on push and encrypts them with its AWS-managed KMS key. The registry API and Docker endpoints each use one network interface in the private subnet. Only the cluster security group can connect over HTTPS. Both nodes can download image layers through the existing regional S3 gateway. [ECR private connectivity](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)

The Learner Lab apply created six resources and updated the S3 gateway endpoint policy in place. The following plan returned exit code 0. The private agent pulled and executed the published `v0.1.0` image by digest. [Live pull result](evidence/ecr-private-agent.txt)

The two interfaces together cost about **$0.02/hour** in one availability zone, plus data processing and ECR storage. [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)

## Enable publishing after provisioning

1. Use the [Learner Lab guide](learner-lab.md) with its existing state. After applying the reviewed plan, `terraform -chdir=infra output -state="$STATE" -raw ecr_repository_url` returns the image URI.
2. In GitHub, configure the `ecr-publish` environment to allow deployments from the **branch `main` only**. The repository variable `ECR_REGISTRY` contains the hostname portion of the image URI. The environment secret `ECR_PUSH_PASSWORD` contains the expiring Docker password. Renew it from an active lab session and an authenticated GitHub CLI with the following command in the checkout.

   ```bash
   set -o pipefail
   aws ecr get-login-password --region us-east-1 | gh secret set ECR_PUSH_PASSWORD --env ecr-publish
   ```

3. Set the repository variable `ECR_PUBLISH_ENABLED` to `true` when the registry is available. On the next push to `main`, CI tests the Linux image in Compose with PostgreSQL, scans it with Trivy and saves it for one day. **Publish ECR** waits for the full CI run to pass, then pushes that artifact with the full commit SHA as its tag. To retry after the artifact expires, rerun all jobs of the relevant `main` CI run. Renew the ECR password when it expires. [ECR authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)
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
