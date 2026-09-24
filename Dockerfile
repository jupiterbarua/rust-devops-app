# syntax=docker/dockerfile:1

# ---- Stage 1: plan dependencies (cargo-chef) ----
# cargo-chef lets Docker cache the dependency build as its own layer,
# so changing your code does not recompile all crates every time.
# Builder and runtime both use Debian 12 (bookworm), so glibc versions match.
FROM rust:1-slim-bookworm AS chef
RUN cargo install cargo-chef --locked
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ---- Stage 2: build ----
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --locked --bin rust-devops-app

# ---- Stage 3: minimal runtime ----
# Distroless: no shell, no package manager, runs as non-root.
# Small attack surface and a small image (~30 MB).
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime
COPY --from=builder /app/target/release/rust-devops-app /usr/local/bin/rust-devops-app
ENV PORT=8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/rust-devops-app"]
