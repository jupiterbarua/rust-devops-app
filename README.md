# rust-devops-app

A production-style REST API in Rust (Axum + PostgreSQL), with a complete delivery pipeline: containerized builds, automated quality gates, and keyless deployment of images to AWS.

The service is deliberately small. The focus is on how it is built, tested, packaged and shipped.

## Architecture

```
GitHub push / PR ──► GitHub Actions
                      ├─ lint:   cargo fmt + clippy (warnings fail the build)
                      ├─ test:   unit + integration tests against a Postgres service container
                      └─ docker: multi-stage build ──► Amazon ECR
                                 (main only, AWS OIDC auth, image tagged with commit SHA)
```

## Tech stack

| Area          | Tools                                                   |
|---------------|---------------------------------------------------------|
| Application   | Rust, Axum, Tokio, SQLx, PostgreSQL 16                  |
| Observability | Structured JSON logging (`tracing`), health/readiness probes |
| Container     | Multi-stage Docker build, cargo-chef, distroless runtime |
| CI/CD         | GitHub Actions                                          |
| Cloud         | AWS ECR, IAM with GitHub OIDC                           |

## Features

- **12-factor configuration.** All config comes from environment variables, so the same image runs locally, in CI and in the cloud.
- **Automatic database migrations** on startup, embedded in the binary at compile time.
- **Liveness and readiness endpoints** built for Kubernetes probes.
- **Graceful shutdown** on SIGTERM, so in-flight requests finish during rolling deployments.
- **Connection pooling** with bounded size and acquire timeouts, so a slow database cannot hang requests forever.

## Run locally

```bash
docker compose up --build            # API on http://localhost:8080

curl localhost:8080/health
curl -X POST localhost:8080/items -H 'content-type: application/json' -d '{"name":"hello"}'
curl localhost:8080/items
```

Run the tests (integration tests need Postgres):

```bash
docker compose up -d db
DATABASE_URL=postgres://app:app@localhost:5432/app cargo test -- --include-ignored
```

## API

| Method | Path          | Purpose                                  |
|--------|---------------|------------------------------------------|
| GET    | `/health`     | Liveness: process is running             |
| GET    | `/ready`      | Readiness: database is reachable         |
| GET    | `/items`      | List items                               |
| POST   | `/items`      | Create item `{"name": "..."}`            |
| GET    | `/items/{id}` | Get one item                             |

## Configuration

| Variable       | Required | Default | Description                  |
|----------------|----------|---------|------------------------------|
| `DATABASE_URL` | yes      | —       | PostgreSQL connection string |
| `PORT`         | no       | `8080`  | HTTP listen port             |
| `RUST_LOG`     | no       | `info`  | Log level / filter           |

## Design decisions

- **OIDC instead of AWS access keys.** No long-lived secrets are stored in GitHub. Credentials are short-lived, and the IAM role can only be assumed from this repository's `main` branch.
- **Images tagged with the commit SHA, not `latest`.** Every deployed image traces back to exact code, and rollbacks are deterministic.
- **Distroless, non-root runtime image.** No shell or package manager in the image, which keeps it small (~30 MB) and reduces the attack surface.
- **cargo-chef dependency caching.** Dependencies are built in their own Docker layer, so code changes don't recompile every crate.
- **Separate `/health` and `/ready`.** Kubernetes restarts a pod on a failed liveness check but only removes it from traffic on a failed readiness check. A database outage should not cause restart loops.
- **Least-privilege CI.** Workflow permissions default to read-only. Only the image job gets the `id-token` permission, and only pushes to `main` publish images.

## Roadmap

- Infrastructure as code with Terraform (VPC, RDS, ECR)
- Kubernetes deployment with Helm (kind locally, then Amazon EKS)
- Image vulnerability scanning (Trivy) and dependency auditing (`cargo audit`)
- Tag-based release workflow (`v1.2.0`)
