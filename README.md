# rust-devops-app

A REST API in Rust (Axum + PostgreSQL), delivered to AWS through a complete
DevOps toolchain: automated CI with quality and security gates, keyless image
publishing, infrastructure as code with Terraform, deployment to Kubernetes
(k3s and Amazon EKS) with Helm, and monitoring with Prometheus and Grafana.

The service itself is deliberately small. The repository is about how it is
built, tested, packaged, provisioned, deployed and observed.

📖 **Step-by-step guide:** [From Cargo to Cluster](https://jupiterbarua.github.io/rust-devops-app/) (work in progress)

## Architecture

```text
                         ┌────────────────────────────────────────────┐
 pull request ──────────▶│ GitHub Actions (CI)                        │
                         │  lint ─┐                                   │
                         │  audit ┼─▶ build image                     │
                         │  test ─┘   (Postgres service container)    │
 merge to main ─────────▶│            └─ push to ECR (OIDC, SHA tag)  │
                         │            └─ deploy via SSM Run Command   │
 tag v*.*.* ────────────▶│ promote existing image to version tag      │
                         └──────────────────────┬─────────────────────┘
                                                │ no stored AWS keys
 ┌──────────────────────────────────────────────▼─────────────────────────────┐
 │ AWS eu-central-1 (Terraform, remote state in S3)                           │
 │                                                                            │
 │  ECR ───────────── images ───────────────┐                                 │
 │                                          ▼                                 │
 │  VPC  ┌ public subnets (2 AZs) ─────────────────────────────┐              │
 │       │  k3s node (EC2)     EKS node group     ALBs          │              │
 │       │  └ Traefik          └ AWS LB Controller              │              │
 │       │    rust-app pods      rust-app pods                  │              │
 │       │    monitoring stack   monitoring stack               │              │
 │       └──────────────────────────┬───────────────────────────┘              │
 │       ┌ private subnets ─────────▼───────────┐                              │
 │       │  RDS PostgreSQL (password in          │                              │
 │       │  Secrets Manager, never in code)      │                              │
 │       └───────────────────────────────────────┘                              │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Repository layout

```text
.github/
  workflows/
    ci.yml          # lint, audit, test, build, push to ECR, deploy to k3s
    dev.yml         # fast checks on the dev branch
    release.yml     # version tags: promote an existing image, no rebuild
    book.yml        # build and publish the guide to GitHub Pages
  dependabot.yml    # weekly updates for actions and crates
book/               # the guide (mdBook)
charts/rust-app/    # Helm chart: app, ingress, ServiceMonitor, alerts, dashboard
infra/terraform/    # all AWS infrastructure
k8s/                # in-cluster PostgreSQL for clusters without RDS
monitoring/         # kube-prometheus-stack values (k3s and EKS)
migrations/         # SQL migrations, embedded in the binary
scripts/            # deploy.sh, install-monitoring.sh
src/  tests/        # the Rust service and its tests
Dockerfile  docker-compose.yml
```

## Tech stack

| Area | Tools |
|---|---|
| Application | Rust, Axum, Tokio, SQLx, PostgreSQL 16 |
| Containers | Docker multi-stage builds, cargo-chef, distroless runtime |
| CI/CD | GitHub Actions, GitHub OIDC, Amazon ECR, AWS Systems Manager |
| Infrastructure | Terraform, S3 remote state, VPC, RDS, EC2, EKS, IAM, AWS Budgets |
| Kubernetes | k3s, Amazon EKS, Helm, Traefik, AWS Load Balancer Controller, EKS Pod Identity |
| Observability | Prometheus metrics, kube-prometheus-stack, Grafana, Alertmanager, JSON logs |
| Security | Secrets Manager, least-privilege IAM, pinned actions, cargo-deny, ECR image scanning |

## The application

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness: the process is running |
| GET | `/ready` | Readiness: the database is reachable |
| GET | `/version` | Version of the running build |
| GET | `/metrics` | Prometheus metrics |
| GET | `/items` | List items |
| POST | `/items` | Create an item: `{"name": "..."}` |
| GET | `/items/{id}` | Get one item |

- **Configuration from the environment** (twelve-factor): the same image runs
  locally, in CI, on k3s and on EKS.
- **Migrations embedded at compile time** and applied on startup.
- **Graceful shutdown** on `SIGTERM`, so in-flight requests complete during
  rolling updates.
- **Bounded connection pool** with acquire timeouts, so a slow database cannot
  hang requests.
- **Structured JSON logs** via `tracing`.
- **RED metrics** via middleware: request count and latency histogram labelled
  by method, route pattern and status, plus business and database error counters.

| Variable | Required | Default | Description |
|---|---|---|---|
| `DATABASE_URL` | yes | — | PostgreSQL connection string |
| `PORT` | no | `8080` | HTTP listen port |
| `RUST_LOG` | no | `info` | Log level / filter |

## CI/CD

**On every pull request to `main`**, four jobs run. The first three run in
parallel; the image build only starts when all of them pass:

| Job | What it does |
|---|---|
| Format & Clippy | `cargo fmt --check`, Clippy with warnings as errors |
| Dependency audit | `cargo-deny` against the RustSec advisory database |
| Tests (with Postgres) | Unit and integration tests against a real PostgreSQL service container |
| Build image | Multi-stage Docker build with layer caching (built, not pushed) |

**On merge to `main`**, the image is pushed to ECR, tagged with the commit SHA,
and deployed to the k3s cluster through SSM Run Command. The deploy job skips
cleanly when no cluster is running.

**On a version tag** (`v1.2.0`), the release workflow adds the version tag to the
image that was already built and tested for that commit. Nothing is rebuilt.

Supporting practices:

- `main` is protected by a ruleset: pull requests only, required status checks,
  no force pushes or deletion.
- All third-party actions are pinned to full commit SHAs; Dependabot proposes
  updates weekly, together with Cargo dependency updates.
- The workflow token is read-only by default; only jobs that talk to AWS receive
  `id-token: write`.
- Concurrent runs on a pull request cancel each other; runs on `main` queue, so a
  deployment is never cancelled halfway.

## Infrastructure

All AWS resources are defined in `infra/terraform`. State is stored in a
versioned, encrypted S3 bucket with native state locking.

| File | Resources |
|---|---|
| `network.tf` | VPC, public and private subnets in two AZs, internet gateway, route tables |
| `database.tf` | RDS PostgreSQL in private subnets, subnet group, security group |
| `ecr.tf` | Container registry with immutable tags and scan on push |
| `iam.tf` | GitHub OIDC provider, CI role (push to ECR, trigger deployments) |
| `k3s.tf` | k3s node on EC2: instance role, Session Manager access, no inbound SSH |
| `eks.tf` | EKS cluster, managed node group, access entries |
| `lbc.tf` | Pod Identity agent, IAM role for the AWS Load Balancer Controller |
| `budget.tf` | Monthly cost budget with actual and forecast email alerts |

Account-specific values (GitHub IDs, alert email, allowed IP) live in a
git-ignored `terraform.tfvars`; see `terraform.tfvars.example`.

There is deliberately **no NAT gateway**: nodes run in public subnets with no
inbound access except from an allow-listed IP, which keeps the environment
inexpensive to run and to tear down.

## Kubernetes and Helm

The `charts/rust-app` chart deploys the service to any cluster:

- Rolling updates with `maxUnavailable: 0`; liveness on `/health`, readiness on `/ready`.
- Database credentials from an existing Secret created at deploy time; a
  config checksum annotation restarts pods when connection details change.
- A `ServiceMonitor`, `PrometheusRule` and Grafana dashboard ship with the chart and
  are only rendered when the cluster has the monitoring stack installed.
- `values.yaml` targets k3s (Traefik); `values-eks.yaml` switches to an
  internet-facing ALB with IP targets and readiness-based health checks.

`scripts/deploy.sh` is idempotent and handles everything for a deployment:
it refreshes the ECR pull secret, uses RDS when it exists (reading the password
from Secrets Manager and building an SSL connection string) or falls back to an
in-cluster PostgreSQL, lints the chart, and runs `helm upgrade --install`.

| Platform | Ingress | Image pulls | AWS access for pods |
|---|---|---|---|
| k3s on EC2 | Traefik | Pull secret, refreshed on each deploy | Instance role |
| Amazon EKS | ALB via AWS Load Balancer Controller | Node IAM role | EKS Pod Identity |

## Observability

`scripts/install-monitoring.sh` installs kube-prometheus-stack on either platform
(`PLATFORM=k3s` or `PLATFORM=eks`). Prometheus discovers the application pods
through the chart's `ServiceMonitor` and scrapes each pod individually.

The **Rust App – RED overview** dashboard shows request rate, 5xx error rate,
p50/p95/p99 latency, ready pods, restarts, memory and items created.

| Alert | Condition | Severity |
|---|---|---|
| `RustAppHighErrorRate` | > 5% of requests return 5xx for 2 minutes | critical |
| `RustAppPodsNotReady` | Fewer available pods than desired for 2 minutes | warning |
| `RustAppDown` | No pod can be scraped for 1 minute | critical |

## Security

- **No long-lived credentials anywhere.** CI authenticates with GitHub OIDC; the
  trust policy accepts only this repository's `main` branch and `v*` tags,
  using GitHub's immutable subject format with numeric owner and repository IDs.
- **Least-privilege IAM.** The CI role can push to one repository and send
  commands only to instances carrying a specific tag; the node role can read
  only RDS-managed secrets.
- **No inbound management access.** Servers are reached through Session Manager;
  deployments use SSM Run Command instead of SSH.
- **Database isolated** in private subnets, credentials generated and stored by
  Secrets Manager, connections over TLS.
- **Distroless, non-root image**, without shell or package manager.
- **Public endpoints restricted** to an allow-listed IP range.

## Getting started

**Run locally**

```bash
docker compose up --build            # API on http://localhost:8080
curl localhost:8080/health
curl -X POST localhost:8080/items -H 'content-type: application/json' -d '{"name":"hello"}'

docker compose up -d db
DATABASE_URL=postgres://app:app@localhost:5432/app cargo test -- --include-ignored
```

**Provision infrastructure**

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan
terraform apply
```

**Deploy to k3s** (on the k3s node, via Session Manager)

```bash
./scripts/install-monitoring.sh
./scripts/deploy.sh                 # newest image in ECR, or pass a tag
```

**Deploy to EKS** (requires the AWS Load Balancer Controller)

```bash
export KUBECONFIG=~/.kube/eks.yaml
PLATFORM=eks ALLOW_CIDR=<your-ip>/32 ./scripts/install-monitoring.sh
VALUES_FILE=charts/rust-app/values-eks.yaml ALLOW_CIDR=<your-ip>/32 ./scripts/deploy.sh
```

**Tear down.** Load balancers are created by the controller, not by Terraform,
so remove the Helm releases first:

```bash
helm uninstall rust-app -n rust-app
helm uninstall kube-prometheus-stack -n monitoring
# wait until no load balancers remain, then:
terraform destroy -target=aws_eks_cluster.main
terraform destroy -target=aws_instance.k3s -target=aws_db_instance.main
```

## Design decisions

- **OIDC instead of access keys**: short-lived credentials, nothing to rotate,
  scoped to one repository and branch.
- **Commit-SHA tags in an immutable registry**: every running image maps to exact
  code; releases add a version tag instead of rebuilding.
- **Separate liveness and readiness**: a database outage takes pods out of
  traffic without causing restart loops.
- **Monitoring ships with the application**: the chart carries its own scrape
  config, alerts and dashboard, versioned with the code.
- **Route patterns as metric labels**: `/items/{id}` instead of raw URLs keeps
  label cardinality bounded.
- **`pathType: Prefix` for every Ingress**: behaves the same with Traefik and
  the AWS Load Balancer Controller.

## Roadmap

- Terraform in CI: `plan` on pull requests, `apply` after merge
- Image and infrastructure scanning: Trivy, Checkov
- Staging and production environments with approval-gated releases
- Alertmanager notifications (email / Slack)
- Centralised logging with Loki
- GitOps with Argo CD, autoscaling, HTTPS with cert-manager and ACM,
  External Secrets Operator on EKS
