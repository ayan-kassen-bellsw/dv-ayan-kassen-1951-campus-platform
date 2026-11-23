# Deploy scholarship applications to k3s

The two application replicas serve HTTP through Traefik. Each connects as `app_rw` to the private PostgreSQL Service. The database stores application rows and attachment bytes on its persistent volume, so a different replica can serve the next request. An application Pod runs under UID 10001 with a read-only root filesystem and a bounded temporary directory for multipart uploads.

The [Learner Lab database checks](evidence/postgres-k3s.json) record the bound volume, role restrictions and external connection test. The [local two-node exercise](evidence/app-k3s-local.json) records attachment sharing, autoscaling, rolling update, rollback and control-plane maintenance in an isolated k3d cluster. The database volume is local to its worker, so loss of that worker requires recovery of the database.

## Prepare the cluster

1. Provision the two-node cluster, the private ECR repository and its private network endpoints. Publish the application image built from a commit that supports the database attachment backend. The [ECR guide](ecr.md) explains publication and the private-agent pull check.
2. Deploy the PostgreSQL manifests in `k8s/postgres`. The namespace is `dv-ayan-kassen-1951`, the database is `campus` and the client-facing Service is `dv-ayan-kassen-1951-postgres`. Mirror or preload the PostgreSQL image for the private node according to the database deployment instructions.
3. Provision a Secret named `dv-ayan-kassen-1951-app-credentials` in the same namespace from your secret manager. Its `rw-password` key must have the same value provisioned for PostgreSQL's `app_rw` role. Its `secret-key` key must contain at least 32 characters. The Deployment mounts these two keys as read-only files. After rotating the corresponding database password and synchronizing this Secret, run `kubectl -n dv-ayan-kassen-1951 rollout restart deployment/dv-ayan-kassen-1951-app` so the connection pool picks up the new password.
4. Configure the ECR pull Secret on the server using its instance role. The API endpoint must allow `ecr:GetAuthorizationToken`, both nodes need the registry and S3 layer endpoints, and the repo must allow image reads. From a checkout on the server, install the refresh timer after creating the namespace. The timer obtains a fresh password every six hours, including after a server restart. Only kubelet uses this Secret to pull images.

   ```bash
   sudo install -m 0755 ops/deploy-app.sh /usr/local/sbin/dv-ayan-kassen-1951-deploy-app
   sudo install -m 0644 k8s/app/host/dv-ayan-kassen-1951-ecr-refresh.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl start dv-ayan-kassen-1951-ecr-refresh.service
   sudo systemctl enable --now dv-ayan-kassen-1951-ecr-refresh.timer
   systemctl list-timers dv-ayan-kassen-1951-ecr-refresh.timer
   ```

## Render and deploy a release

Use Bash, `kubectl` (or the server's `/usr/local/bin/k3s`) and a kubeconfig for the target cluster. Set `APP_OWNER` privately to the student's full name and ID for the assessed deployment. The value appears on the public home page and `/info`. Set `GIT_SHA` and `APP_VERSION` to the commit and version of the published image. From a host with authorized AWS CLI access, resolve the full SHA tag to a digest and render the manifests.

```bash
export APP_MODE=cloud
repo=dv-ayan-kassen-1951-scholarship-applications
uri=$(aws ecr describe-repositories --region us-east-1 --repository-names "$repo" \
  --query 'repositories[0].repositoryUri' --output text)
digest=$(aws ecr describe-images --region us-east-1 --repository-name "$repo" \
  --image-ids "imageTag=$GIT_SHA" --query 'imageDetails[0].imageDigest' --output text)
export APP_IMAGE="$uri@$digest" APP_VERSION GIT_SHA APP_OWNER
bash ops/deploy-app.sh render
bash ops/deploy-app.sh apply
```

For a local k3d cluster, import a tagged build into **every** schedulable node. Set `APP_MODE=local` and `APP_IMAGE` to that tag, for example `campus-app:k3d-test`. The same deployment script uses the preloaded image and the same database-backed attachments. Local testing can supply test-only secrets and a test owner.

## Check the public path

Set `URL` to the HTTP URL of the server public address or the local Traefik port. A successful readiness check verifies the database connection and storage. The returned item ID and the database query below demonstrate that a submission through Ingress persisted.

```bash
curl -fsS "$URL/readyz"
curl -fsS "$URL/info"
id=$(curl -fsS --json '{"title":"Ingress scholarship check","description":"Deployment verification"}' \
  "$URL/api/items" | jq -er '.id')
curl -fsS "$URL/api/items/$id"
kubectl -n dv-ayan-kassen-1951 get pods,svc,ingress,hpa,pvc
```

Use the read-only database role in the PostgreSQL verification instructions to check `SELECT id,title FROM items WHERE id = ...` for that ID. Use Metrics Server for the HPA. Its minimum is two replicas, its CPU target is 70% of each Pod's 100m request, and its maximum is four. Compare `kubectl top pods` with `kubectl -n dv-ayan-kassen-1951 get hpa -w` during a load test.

Each release generates a ConfigMap named from its contents. The Deployment adds a replacement Pod and waits for readiness before retiring an old one. Keep the generated ConfigMaps referenced by retained revisions. To return to the previous release and verify the rollout:

```bash
kubectl -n dv-ayan-kassen-1951 rollout undo deployment/dv-ayan-kassen-1951-app
kubectl -n dv-ayan-kassen-1951 rollout status deployment/dv-ayan-kassen-1951-app
curl -fsS "$URL/info"
```
