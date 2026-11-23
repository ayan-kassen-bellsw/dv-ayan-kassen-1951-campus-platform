# Scholarship applications

> **CSS4003 DevOps 2 — Final Project (Narxoz University).**
> Assignment: [final-project.pdf](https://weeebdev-edu.github.io/css4003/pdfs/final-project.pdf) · Rubric: [final-project-rubric.pdf](https://weeebdev-edu.github.io/css4003/pdfs/final-project-rubric.pdf) · Report template: [final-project-report-template.pdf](https://weeebdev-edu.github.io/css4003/pdfs/final-project-report-template.pdf) · Free tier guide: [free-tier-guide.pdf](https://weeebdev-edu.github.io/css4003/pdfs/free-tier-guide.pdf)


A FastAPI service for recording scholarship applications. Each item is one
application with a title, description and an optional supporting document.
The local stack runs the API and PostgreSQL with Docker Compose.
On k3s, Traefik routes requests to two application replicas. They share the PostgreSQL database for application records and supporting documents. See the [application deployment guide](docs/k3s-app.md) for release, verification and rollback commands.

## What the app does

- Stores **scholarship applications** in PostgreSQL.
- Stores **attachments** in object storage: a local folder, **Amazon S3** or
  **Google Cloud Storage**.
- Exposes **health checks**, **Prometheus metrics** and **JSON logs**.
- Has a **password policy checker** you can use in your security checks.

## Run locally

Use Docker with Compose. In PowerShell, run `Copy-Item .env.example .env`
for the first setup. Edit `.env` to add your full student ID to `APP_OWNER`
and replace the example credentials. Generate a fresh value for each secret
with `python -c "import secrets; print(secrets.token_urlsafe(48))"`.
`.env` is excluded from Git.

```powershell
docker compose up --build --detach
Invoke-RestMethod http://localhost:8000/readyz
Invoke-RestMethod http://localhost:8000/info
$application = @{ title = 'Merit scholarship application'; description = 'Fall semester' } | ConvertTo-Json
Invoke-RestMethod http://localhost:8000/api/items -Method Post -ContentType application/json -Body $application
Invoke-RestMethod http://localhost:8000/api/items
```

Readiness reports `ready: true` when both database and attachment storage
respond. The info endpoint reports the owner, database engine and version.
To run local monitoring, use `docker compose --profile monitoring up --build --detach`.
Prometheus listens on port 9090 and Grafana on 3000.
Use `docker compose --profile monitoring down` to stop the stack.

Run the tests and the linter without Docker:

```bash
make venv && make test && make lint
```

## Pull request checks

GitHub Actions runs the following checks on pull requests and pushes to `main`.

- Ruff checks lint and formatting. Pytest runs the application tests.
- Gitleaks scans the Git history for exposed secrets.
- `pip-audit` checks the resolved application and development dependencies for known vulnerabilities.
- CI builds the application image and starts it with PostgreSQL using Docker Compose. It checks readiness, saves a scholarship application, and tests the password endpoint with 15- and 16-character inputs. Trivy scans the built image and fails the check on HIGH or CRITICAL findings.
- The Terraform job checks formatting, validates the configuration and scans it with Trivy. Offline plans verify both the standard AWS and Learner Lab configurations, including the two EC2 nodes and their bootstrap permissions.

The [ECR guide](docs/ecr.md) covers publishing that same tested image from `main`, giving a release its immutable version tag, and verifying a pull from the private agent.

The [PostgreSQL guide](docs/postgres.md) covers deployment on the private worker, credential rotation, and the k3s test that verifies role permissions and persistence across Pod replacement.

## AWS network

For AWS Academy, follow the [Learner Lab deployment guide](docs/learner-lab.md). It covers temporary credentials, the existing `LabInstanceProfile`, and how to use the same Terraform state on the next run. The [recorded Kubernetes API result](docs/evidence/k3s-ready.json) shows both nodes `Ready` in `us-east-1`.

The Terraform configuration in `infra/` defines the project's IPv4 network and two EC2 instances. `aws_region` defaults to `us-east-1`, `vpc_cidr` to `10.56.0.0/16`, and `resource_prefix` to `dv-ayan-kassen-1951`.

| Network | CIDR | Routing |
|---|---|---|
| VPC | `10.56.0.0/16` | Both subnets can route within the VPC. Security groups control which connections are allowed. |
| Public subnet | `10.56.1.0/24` | Local VPC route, regional S3 gateway endpoint and a default route to the internet gateway. |
| Private subnet | `10.56.2.0/24` | Local VPC route and regional S3 gateway endpoint. |

Both subnets default to `us-east-1a`. Both nodes use the `app` security group. The server also uses `ingress` and receives a public IPv4 address for web traffic. The agent has only a private address.

| Source | Destination | Allowed traffic |
|---|---|---|
| Internet | `ingress` | TCP 80 and 443 for web requests |
| `app` | `ingress` | TCP 6443 for the k3s API |
| `app` | `app` | UDP 8472 for the overlay and TCP 10250 for kubelet metrics |
| `app` | `database` | TCP 5432 for PostgreSQL |
| `app` | Regional S3 prefix list | TCP 443 for bootstrap artifacts, the agent join token and ECR image layers |
| `app` | `registry` | TCP 443 to the private ECR API and Docker endpoints |

The security groups keep SSH and the Kubernetes API closed to the internet. The private agent obtains its installation files through the S3 gateway endpoint. The cluster can start without a NAT gateway.

To preview changes against your AWS account, select your AWS CLI profile or session credentials and run these commands from the repository root:

```sh
terraform -chdir=infra init -lockfile=readonly
terraform -chdir=infra validate
terraform -chdir=infra plan
```

To repeat the CI plan locally, run `bash .github/scripts/terraform-plan.sh` with Terraform and `jq` installed. It uses the locked AWS provider, an empty temporary state and a fixture AMI ID. An authenticated plan resolves the official Amazon Linux 2023 x86_64 AMI through the regional AWS public SSM parameter by default. To pin a particular Amazon Linux 2023 release, set `TF_VAR_ami_id` to its regional AMI ID.

## k3s on EC2

| Node | EC2 type | Private address | Purpose |
|---|---|---|---|
| Server | `t3.small` | `10.56.1.10` | Kubernetes control plane and web ingress |
| Agent | `t3.small` | `10.56.2.10` | Joins the server over private TCP 6443 and runs workloads |

Before applying the configuration from a new checkout, run the following from the repository root in Bash with `curl` and `sha256sum` installed. It downloads the pinned k3s binary, bundled system images and checksum manifest, verifies all three against the committed SHA-256 digests, and caches them in `infra/.artifacts/`. An offline plan can run before this download. [Pinned k3s release](https://github.com/k3s-io/k3s/releases/tag/v1.37.2%2Bk3s1)

```sh
bash infra/bootstrap/download.sh
```

In a standard AWS account, the identity running an apply needs access to the EC2, VPC, S3 and KMS resources, permission to create the node roles and instance profiles, and permission to pass those roles to EC2. Terraform uploads the release files to a private S3 bucket encrypted with a dedicated KMS key, then starts the instances. Learner Lab uses the existing instance profile and the AWS-managed S3 KMS key.

Cloud-init installs systemd services on both nodes. Each node checks the manifest against the digest from Terraform and uses it to verify the binary and images. The server generates a separate agent credential and publishes the CA-bound agent token. The agent retrieves it through the S3 endpoint using its instance credentials and connects to the server's private address. Supply application images separately when deploying workloads.

The single server keeps the Kubernetes datastore on its root volume. Server replacement creates a fresh cluster and replaces its agent. Once private administration access is available, run `sudo /usr/local/bin/k3s kubectl get nodes -o wide` on the server and check that both private addresses report `Ready`. Terraform destroy empties the dedicated bootstrap bucket, including the generated agent token. Keep application data in a separate bucket. Budget for EC2, EBS, S3, KMS and the server's public IPv4 address when provisioning this stack.

## Configuration (environment variables)

Every setting is an environment variable. **Any secret can instead be read from
a file**: set `NAME_FILE=/path/to/file` (this is how Kubernetes and Docker
secrets are mounted).

| Variable | Required | Example / default | Meaning |
|---|---|---|---|
| `SECRET_KEY` | **yes** | 48 random chars | App secret. The app refuses to start if it's missing or shorter than 32 characters. |
| `DB_URL` | **yes** | `postgresql+psycopg://app_rw:${DB_PASSWORD}@postgres:5432/campus` | Database connection string. |
| `DB_PASSWORD` | if `DB_URL` has `${DB_PASSWORD}` | from your secret manager | Filled into `DB_URL` and URL-encoded by the app. |
| `CLICKHOUSE_URL` | no | unset | Leave unset for this project. |
| `STORAGE_BACKEND` | no | `local` · `s3` · `gcs` · `database` | The Kubernetes deployment stores attachments in PostgreSQL so all replicas can serve the same file. |
| `BUCKET` | for s3/gcs | `/app/data/uploads` for local Compose | Bucket name or local folder for application documents. |
| `APP_NAME` | no | `Scholarship applications` | Shown on the home page. |
| `APP_OWNER` | for course submission | Your name and full student ID | Shown on `/` and `/info`. |
| `APP_VERSION`, `GIT_SHA` | no | set by your CI | Shown on `/info`; useful to prove which release is running. |
| `LOG_LEVEL`, `LOG_FORMAT` | no | `INFO`, `json` | Logging. Keep JSON in production. |
| `PASSWORD_MIN_LENGTH` | no | `16` | Minimum number of characters accepted by the checker. |
| `PASSWORD_REQUIRE_SYMBOL` | no | `false` | Set to `true` to require punctuation. Uppercase, lowercase, a digit and the common-password check always apply. |

Cloud credentials are **not** configured here. boto3 (AWS) and
google-cloud-storage (GCP) use their default credential chains: an instance
role or service account in the cloud, `AWS_ENDPOINT_URL` for local emulators.
Never put access keys in the image, the repo or `.env` files you commit.

## Endpoints

| Method & path | What it does |
|---|---|
| `GET /` | HTML page with app name, owner, version and the host that served it |
| `GET /info` | JSON: version, git sha, hostname, db engine, storage backend |
| `GET /healthz` | Liveness: the process is up (no dependencies checked) |
| `GET /readyz` | Readiness: database and storage reachable, else **503** |
| `GET /metrics` | Prometheus: `http_requests_total`, `http_request_duration_seconds`, `items_total`, `db_up` |
| `GET/POST /api/items` | List (with `limit`, `offset`) / create items |
| `GET/PUT/DELETE /api/items/{id}` | Read / update / delete one item |
| `POST/GET /api/items/{id}/attachment` | Upload / download a file (multipart field `file`, max 10 MB) |
| `POST /api/admin/check-password` | `{"password": "..."}` → which policy rules pass |

Interactive API docs: `http://localhost:8000/docs`.

## What's in the repo

```
app/                 the service (FastAPI, SQLAlchemy, prometheus-client)
app/sql/             EXAMPLE least-privilege roles for PostgreSQL / MySQL, ClickHouse DDL
tests/               pytest suite (uses SQLite, no services needed)
Dockerfile           multi-stage, non-root, with HEALTHCHECK
compose.yaml         LOCAL development only
infra/               AWS networking, k3s EC2 nodes and cloud-init bootstrap
deploy/local/        Prometheus + Grafana config for the local monitoring profile
.github/workflows/   CI checks for code, dependencies, the image and the running service
```
