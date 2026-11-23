# Scholarship applications database

PostgreSQL 17 runs as a single StatefulSet on a worker in the `dv-ayan-kassen-1951` namespace. The client Service has a cluster-only address at `dv-ayan-kassen-1951-postgres:5432`. A NetworkPolicy admits TCP 5432 from the main and production application Pods in that namespace. Their `app.kubernetes.io/name` label is `scholarship-applications` or `scholarship-applications-prod`. The cluster must enforce NetworkPolicy for this rule to take effect.

The StatefulSet requests a 2 GiB ReadWriteOnce claim from the default StorageClass. K3s local-path storage keeps the data on the selected worker when the Pod restarts. Losing that worker or its disk requires restoring a backup. The database has one replica. Its PVC is retained when the StatefulSet is deleted.

## Provision the database

1. Choose the intended kubeconfig/context and create the namespace with `kubectl apply -f k8s/postgres/namespace.yaml`.
2. With an active Learner Lab AWS profile and an authorized cluster connection, run `python ops/sync-platform-secrets.py --initialize --context "$CONTEXT"` on first deployment. For kubectl on the server, use `python ops/sync-platform-secrets.py --initialize -- ssh -T "$SERVER" sudo /usr/local/bin/k3s kubectl` over an authorized, host-key-verified connection. The script initializes missing SSM SecureStrings under `/dv-ayan-kassen-1951/platform/` and syncs credentials to Kubernetes. Later syncs read the existing values. The database Secret is `dv-ayan-kassen-1951-postgres-credentials` with keys `postgres-password`, `admin-password`, `rw-password`, `ro-password`. The application receives its RW password and signing key in a separate Secret.
3. A local cluster with Docker Hub access can use `kubectl apply -k k8s/postgres`. For the private Learner Lab worker, mirror the official `postgres:17.12-bookworm` Linux AMD64 image to the project ECR repository first. Set `PG_IMAGE` to the full ECR repository URI followed by `@sha256:` and its mirrored manifest digest. Supply a valid `dv-ayan-kassen-1951-ecr-pull` registry Secret in the namespace.

   The following overlay selects the mirrored image without editing the checked-in manifests. Run it from the repository root in Bash.

   ```bash
   (
     set -euo pipefail
     : "${PG_IMAGE:?Set the immutable ECR image URI}"
     [[ "$PG_IMAGE" =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/dv-ayan-kassen-1951-scholarship-applications@sha256:[0-9a-f]{64}$ ]]
     work=$(mktemp -d)
     trap 'rm -rf -- "$work"' EXIT
     cp -R k8s/postgres "$work/base"
     cat > "$work/kustomization.yaml" <<EOF
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources: [base]
   images:
     - name: postgres
       newName: ${PG_IMAGE%@*}
       digest: ${PG_IMAGE#*@}
   EOF
     kubectl apply -k "$work"
   )
   ```

4. Wait for the schema and check the worker and claim.

   ```bash
   NS=dv-ayan-kassen-1951
   DB="$NS-postgres"
   kubectl -n "$NS" rollout status "statefulset/$DB" --timeout=5m
   kubectl -n "$NS" get pod "$DB-0" -o wide
   kubectl -n "$NS" get pvc
   ```

## Roles, schema and rotation

On startup, the container validates all four password files for 16 or more characters, uppercase, lowercase and a digit. Symbols are optional. After PostgreSQL starts, the in-container bootstrap connects to the Unix socket using peer authentication as the `postgres` OS user. The bootstrap creates the database if needed and reconciles the roles, ownership, grants and application tables in a transaction. TCP clients authenticate using SCRAM-SHA-256. Provision credentials through this validation path to apply the project's policy.

| Role | Access to the `campus` database |
|---|---|
| `admin` | Owns the application tables and can perform DDL in the public schema |
| `app_rw` | Reads and changes rows and can use ID sequences |
| `app_ro` | Reads application tables for reporting |

For a rotation, update the chosen SSM SecureString and rerun the sync script. After Kubernetes projects the new Secret revision into the database Pod, run `kubectl -n "$NS" exec "$DB-0" -- /opt/scholarship-db/reconcile.sh`. For an RW password rotation, restart the application Deployment to reload its mounted configuration, then check `/readyz` and submit a test application. Coordinate the change because the old password stops authenticating as soon as the transaction commits.

The StatefulSet initializes a dedicated PostgreSQL 17 data directory. To bring data from Compose or another PostgreSQL installation, use a logical dump and restore with the intended application schema and ownership. The production configuration expects a bootstrap superuser named `postgres` and a separate DDL owner named `admin`. Keep an existing volume and its backup until the new database passes the application, role and persistence checks.

## Repeat the acceptance test

From a Linux workstation with Docker and kubectl, run `bash .github/scripts/test-k3s.sh .github/scripts/test-k8s-postgres.sh` in the checkout. It creates an isolated local k3s server and worker. The test connects with each role over TCP, writes and reads a scholarship application, checks that the forbidden operations fail, and replaces the database Pod. Its final query reads the original application using the same persistent volume claim.

CI also scans the rendered Kustomize output. Trivy KSV-0109 flags the bootstrap script filename and SQL password placeholders in the generated ConfigMap. The [scan exception](../.github/scripts/postgres-trivy.rego) matches only that rule for the reviewed ConfigMap content hash. Changing a bootstrap file produces a new hash and requires review. Password values reach the database through the mounted Kubernetes Secret.
