# Containers

In the previous chapter, the service ran with `cargo run` on your own machine.
That works for development, but it is not how software runs in production.
Production servers do not have Rust installed, and "it works on my machine" is
not a deployment strategy.

In this chapter, you package the service as a **container image**: one file
that contains the compiled program and everything it needs to run, and nothing
else. The same image then runs on your laptop, in CI, on a Kubernetes node in
AWS, anywhere Docker or Kubernetes runs.

## The idea

Three terms are worth getting straight first:

| Term | What it is | Analogy |
|---|---|---|
| **Image** | A read-only package: files plus metadata such as which command to start | A recipe and its ingredients, sealed in a box |
| **Container** | A running instance of an image, isolated from other processes | A meal cooked from that box |
| **Registry** | A server that stores images, such as Docker Hub or Amazon ECR | A warehouse for the boxes |

An image is built from a **Dockerfile**, a list of instructions. Each instruction
creates a **layer**, and Docker caches layers: if an instruction and its inputs
have not changed since the last build, Docker reuses the cached layer instead of
running it again. Ordering the Dockerfile so that slow, rarely changing work comes
first is the most important trick for fast builds.

Our goals for the image:

- **Small:** smaller images download faster, start faster, and cost less to store.
- **Secure:** nothing in the image that the program does not need: no shell, no
  package manager, no compiler, and not running as root.
- **Fast to rebuild:** changing one line of Rust should not recompile every
  dependency.

## Step 1: Keep the build context small (`.dockerignore`)

When you run `docker build`, Docker first sends the **build context** (by
default, your whole project folder) to the build engine. A `.dockerignore` file
works like `.gitignore` and keeps unneeded files out.

Create `.dockerignore` in the project root:

```text
target
.git
.github
*.md
docker-compose.yml
.env
book
infra
charts
k8s
scripts
```

The most important line is `target`: Cargo's build folder can be several
gigabytes, and sending it to Docker would make every build slow. Leaving out
`.git` and documentation also avoids rebuilding the image when only those
change. The last five lines cover folders you will add in later chapters; they
are not needed to build the service either.

## Step 2: The multi-stage Dockerfile

A naive Dockerfile would start from the official Rust image, copy the code,
compile it, and run it. That works, but the result is well over a gigabyte,
because it contains the entire Rust toolchain, and it runs as root.

The solution is a **multi-stage build**: several `FROM` sections in one file.
Early stages do the heavy work of compiling. The final stage starts from a tiny
base image and copies in **only** the finished binary. Everything else is
thrown away.

Create `Dockerfile` in the project root:

```dockerfile
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
```

Let's walk through it.

### Stage 1: `chef` and `planner`

```dockerfile
FROM rust:1-slim-bookworm AS chef
RUN cargo install cargo-chef --locked
WORKDIR /app
```

`rust:1-slim-bookworm` is the official Rust image, version 1.x, on Debian 12
("bookworm"), in its slim variant without extra tools. `AS chef` gives the stage
a name, so later stages can build on it. [cargo-chef](https://github.com/LukeMathWalker/cargo-chef)
is installed here, once, and cached as a layer.

```dockerfile
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json
```

The **planner** stage looks at `Cargo.toml` and `Cargo.lock` and writes a
`recipe.json` file that describes only your **dependencies**, not your code.

### Stage 2: `builder`

```dockerfile
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --locked --bin rust-devops-app
```

This is where the caching trick happens:

1. `COPY --from=planner` copies **only** `recipe.json` from the planner stage.
2. `cargo chef cook` compiles **all dependencies** (Axum, Tokio, sqlx, and so on).
   This is the slow part, often several minutes.
3. Only then is your source code copied in and compiled.

Why this order matters: `recipe.json` only changes when your dependencies change.
When you edit `src/lib.rs`, the recipe is identical, so Docker reuses the cached
`cargo chef cook` layer and only recompiles your own crate: seconds instead of
minutes. Without cargo-chef, any code change would invalidate the layer and
recompile everything.

`--locked` tells Cargo to use exactly the versions in `Cargo.lock`, and to fail
if the lock file is out of date. That makes builds **reproducible**: the image
built in CI uses exactly the dependency versions you tested.

### Stage 3: `runtime`

```dockerfile
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime
COPY --from=builder /app/target/release/rust-devops-app /usr/local/bin/rust-devops-app
ENV PORT=8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/rust-devops-app"]
```

The final image is based on Google's **distroless** image. "Distroless" means it
contains no Linux distribution tools at all: no shell, no package manager, no
`ls` or `curl`. It contains only what a compiled program needs to run: the C
standard library (`glibc`), TLS root certificates, and time zone data. The `cc`
variant includes the libraries that Rust binaries link against.

- **`COPY --from=builder`** takes just the compiled binary from the builder stage.
  The compiler, source code, and build artifacts stay behind.
- **`:nonroot` and `USER nonroot:nonroot`** run the program as an unprivileged
  user. If an attacker ever found a flaw in the service, they would not be root
  inside the container, and would have no shell to work with.
- **`EXPOSE 8080`** documents which port the service listens on. It does not
  open anything by itself.
- **`ENTRYPOINT [...]`** in this JSON array form ("exec form") starts the binary
  directly as process number 1 in the container. That matters for graceful
  shutdown: when Docker or Kubernetes stops the container, the `SIGTERM` signal
  goes straight to your program, which then finishes in-flight requests. With
  the shell form (`ENTRYPOINT /usr/local/bin/rust-devops-app`), a shell would
  receive the signal instead, and your program might never see it.

### Why both stages use Debian 12

The builder is `bookworm` and the runtime is `debian12`: the same Debian release.
This is not a coincidence. A Rust binary is linked against the `glibc` version of
the system it was **built** on. If you built on a newer Debian and ran on an
older one, the program would fail at startup with an error like
`GLIBC_2.39 not found`. Keeping both stages on the same release avoids that
whole class of problems.

## Step 3: Build and inspect the image

```bash
docker build -t rust-devops-app:local .
```

`-t` gives the image a name and tag (`name:tag`). The first build takes a few
minutes, mostly in the `cargo chef cook` step.

Look at the result:

```bash
docker images rust-devops-app
```

The image should be **roughly 30 to 40 MB**. Compare that with the Rust build
image (`docker images rust`), which is several hundred megabytes even in its slim
variant.

See its layers:

```bash
docker history rust-devops-app:local
```

You will see the few small layers of the runtime stage only. The builder stages
are not part of the final image at all.

Check that it runs as non-root:

```bash
docker inspect --format '{{.Config.User}}' rust-devops-app:local
```

This prints `nonroot:nonroot`.

## Step 4: Watch the cache work

Change something small in `src/lib.rs`, for example the text returned by
`/health`, and build again:

```bash
time docker build -t rust-devops-app:local .
```

In the output, the `cargo chef cook` step shows `CACHED`, and the build finishes
in a fraction of the first build's time. Now add a new dependency with
`cargo add uuid` and build again: this time `cook` runs again, because the
recipe changed. Remove the dependency again with `cargo remove uuid`, and revert
your `/health` change.

## Step 5: Run everything with Docker Compose

The container needs a database. You could start PostgreSQL and the API with two
`docker run` commands and a shared Docker network, but **Docker Compose** does it
from one file.

Create `docker-compose.yml`:

```yaml
# Local development: `docker compose up --build`
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 5s
      timeout: 3s
      retries: 10
    volumes:
      - pgdata:/var/lib/postgresql/data

  api:
    build: .
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
      RUST_LOG: info
    ports:
      - "8080:8080"
    depends_on:
      db:
        condition: service_healthy

volumes:
  pgdata:
```

What each part does:

- **Two services, one network.** Compose puts both containers on a private
  network where each service is reachable **by its name**. That is why the API's
  `DATABASE_URL` uses `db` as the host name, not `localhost`. Inside a container,
  `localhost` means the container itself.
- **`healthcheck`** runs `pg_isready` every 5 seconds inside the database
  container. The container counts as **healthy** only once PostgreSQL accepts
  connections.
- **`depends_on` with `condition: service_healthy`** makes Compose wait for that
  before starting the API. Without it, the API would often start first, fail to
  connect, and exit.
- **`volumes: pgdata`** stores the database files in a named volume, so your data
  survives `docker compose down` and restarts.
- **`build: .`** builds the API image from your Dockerfile.
- **`ports`** publishes container ports on your machine, in the form
  `host:container`.

Start it:

```bash
docker compose up --build
```

Then, in a second terminal:

```bash
curl localhost:8080/health; echo
curl -X POST localhost:8080/items \
  -H 'content-type: application/json' -d '{"name":"from docker"}'; echo
curl localhost:8080/items; echo
```

You can also run the integration tests against the Compose database, exactly as
CI will in the next chapter:

```bash
docker compose up -d db
DATABASE_URL=postgres://app:app@localhost:5432/app cargo test -- --include-ignored
```

## Step 6: Experiments

**Graceful shutdown in a container.** With the stack running, stop the API:

```bash
docker compose stop api
docker compose logs api | tail -2
```

The last log line is `shutdown signal received`. `docker stop` sent `SIGTERM`,
and because of the exec-form `ENTRYPOINT`, your program received it directly.

**No shell, by design.** Try to open a shell in the running API container:

```bash
docker compose up -d
docker compose exec api sh
```

It fails, because there is no `sh` in a distroless image. That is a security
feature, but it also means you cannot debug inside the container the usual way.
When you really need to, Google provides `:debug` variants of the distroless
images that include a minimal shell. Use them only temporarily, never in
production.

**Data survives restarts.** Run `docker compose down`, then `docker compose up -d`
again, and call `/items`: your items are still there, stored in the `pgdata`
volume. `docker compose down -v` also removes the volume, and with it the data.

## Troubleshooting

**`the lock file needs to be updated but --locked was passed`.** `Cargo.lock` does
not match `Cargo.toml`, usually after editing dependencies without building.
Run `cargo build` locally, then commit the updated `Cargo.lock`. For
applications, always commit `Cargo.lock`.

**The API container exits immediately with a database error.** Usually the
database was not ready yet. Check that `depends_on` uses
`condition: service_healthy`, and that `DATABASE_URL` uses `db`, not `localhost`.

**`exec format error` when running the image.** The image was built for a
different CPU architecture. On an Apple Silicon Mac, images are built for ARM by
default, while most cloud servers use x86. Build for a specific platform with
`docker build --platform linux/amd64 ...`. In this project, CI builds the images
on x86 runners, so this mainly affects local experiments.

**`GLIBC_2.xx not found` at startup.** The builder and runtime stages use
different Debian releases. Keep them on the same release, as explained above.

**`permission denied` when binding to a port.** Non-root users cannot listen on
ports below 1024. Keep the service on port 8080, and map it to another port on
the host if needed (`"80:8080"`).

**Builds are slow every time.** Check the build output for `CACHED` on the
`cargo chef cook` step. If it never appears, something in the planner input keeps
changing, often because `target` or `.git` is missing from `.dockerignore`.

## What you learned

- The difference between images, containers, and registries, and how Docker's
  layer cache works.
- How a multi-stage build keeps the compiler out of the final image.
- How cargo-chef caches dependency builds, so code changes rebuild in seconds.
- Why distroless, non-root images are smaller and more secure, and the trade-off:
  no shell for debugging.
- Why the exec form of `ENTRYPOINT` matters for graceful shutdown.
- Why matching `glibc` versions between build and runtime stages matters.
- How Docker Compose runs several containers with service-name networking,
  health checks, and startup order.

## Practice

1. Write a naive single-stage Dockerfile (`FROM rust:1`, copy, build, run) as
   `Dockerfile.naive`, build it with `docker build -f Dockerfile.naive -t naive .`,
   and compare its size with your multi-stage image.
2. Change the `ENTRYPOINT` to the shell form, rebuild, and run `docker compose stop api`.
   Does the shutdown log line still appear? How long does the stop take? (Docker
   waits 10 seconds before force-killing a container that ignores `SIGTERM`.)
3. Scan your image for known vulnerabilities with
   [Trivy](https://github.com/aquasecurity/trivy): `trivy image rust-devops-app:local`.
   Compare the result with a scan of `rust:1`.
4. Add a `pgadmin` or `adminer` service to `docker-compose.yml` to browse the
   database in your web browser.
5. Research static linking with the `x86_64-unknown-linux-musl` target and the
   `scratch` base image. What are the advantages and the trade-offs compared with
   distroless?

## Interview questions

- What is a multi-stage Docker build, and why does it produce smaller and more
  secure images?
- How does Docker's layer cache work, and how should you order instructions in a
  Dockerfile to benefit from it?
- What is a distroless image? What are its advantages, and what does it make harder?
- Why should containers not run as root?
- What is the difference between the exec form and the shell form of `ENTRYPOINT`,
  and how does it affect graceful shutdown?
- Inside a Docker Compose setup, why does the API connect to `db` instead of
  `localhost`?
- What does `depends_on` guarantee by default, and what does
  `condition: service_healthy` add?
