# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rust-devops-app` — a small Axum + PostgreSQL REST API presented as a portfolio DevOps project. The Rust app is intentionally simple; the focus is the delivery pipeline around it (Docker, GitHub Actions, ECR via OIDC, with Terraform and Kubernetes/EKS on the roadmap). `README.md` is public-facing: keep it professional, and keep personal learning notes or study plans out of it.

## Commands

- Build: `cargo build`
- Lint (same as CI, which fails on any warning): `cargo fmt --all -- --check` and `cargo clippy --all-targets --locked -- -D warnings`
- Run locally with the full stack: `docker compose up --build` (API on `localhost:8080`, Postgres on `localhost:5432`)
- Run the app with `cargo run` against the compose database: `docker compose up -d db`, then `set -a; source .env; set +a` (the app does not load `.env` itself — there is no dotenv crate), then `cargo run`
- Tests without a database: `cargo test` (only `health_returns_ok` runs; DB tests are `#[ignore]`d)
- All tests including DB tests (what CI runs): `docker compose up -d db` then `DATABASE_URL=postgres://app:app@localhost:5432/app cargo test -- --include-ignored`
- Single test: `cargo test create_and_fetch_item -- --include-ignored`
- Docker image: `docker build -t app .`

## Architecture

- `src/lib.rs` holds the whole HTTP layer: `AppState { pool }`, the `app(state) -> Router` builder, and all handlers. `src/main.rs` only does process wiring: JSON logging (`RUST_LOG`, default `info`), config from env vars (`DATABASE_URL` required, `PORT` default 8080), a `PgPool` (max 10 conns, 5 s acquire timeout), running migrations, binding `0.0.0.0`, and graceful shutdown on Ctrl+C/SIGTERM. The split exists so `tests/api.rs` can build the real router and drive it with `tower::ServiceExt::oneshot`, with no network listener.
- Tests that don't touch the DB use `PgPoolOptions::connect_lazy` with a dummy URL, so they run without Postgres. Tests that need a real DB must be marked `#[ignore = "..."]` and read `DATABASE_URL`; CI runs them via `--include-ignored` against a Postgres service container.
- `/health` (liveness, always `ok`) and `/ready` (readiness, runs `SELECT 1`) are deliberately separate for Kubernetes probes. A DB outage should fail readiness only, never liveness.
- SQL uses runtime-checked `sqlx::query` / `query_as` (not the `query!` compile-time macros), so builds need neither `DATABASE_URL` nor sqlx offline data. Keep it that way unless you also add `.sqlx/` offline metadata, or the Docker build and lint job will break.
- Migrations live in `migrations/` and are embedded at compile time by `sqlx::migrate!` (in both `main.rs` and the DB test), then applied at startup. There is no `build.rs`, so after adding a new migration file you may need to touch a source file for Cargo to recompile and pick it up.
- DB errors in handlers are mapped through `internal_error`, which logs the error and returns 500. Validation failures return 422.

## CI / deployment

`.github/workflows/ci.yml` has three jobs: `lint`, `test` (with a Postgres 16 service container), and `docker`, which needs both. The `docker` job always builds, but pushes to ECR (`eu-central-1`, repo `rust-devops-app`, tagged with the commit SHA) only on pushes to `main` when the repo variable `AWS_ROLE_ARN` is set. AWS auth is via GitHub OIDC, not stored keys.

The Dockerfile is multi-stage. It uses cargo-chef to cache the dependency build and a distroless `cc-debian12:nonroot` runtime, so the image has no shell. Builder and runtime are both Debian 12 so glibc matches. Builds use `--locked`, so `Cargo.lock` must stay in sync.

## Local config

`.env` (gitignored and dockerignored) holds `DATABASE_URL`, `PORT` and `RUST_LOG` pointing at the compose Postgres (`app`/`app`/`app`). Inside compose, the `api` service uses host `db` rather than `localhost`.
