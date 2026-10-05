# The Rust Service

Everything in this book exists to build, ship, and run one small program. In
this chapter you write that program: a REST API in Rust that stores items in
PostgreSQL.

The service is small on purpose, but it is built the way production services
are built. It reads its configuration from the environment, writes structured
logs, exposes health endpoints for Kubernetes, shuts down gracefully, and has
both unit and integration tests. Every one of these choices pays off in a later
chapter.

## The idea

The API has a handful of endpoints:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | **Liveness:** is the process running? |
| `GET` | `/ready` | **Readiness:** can it reach the database? |
| `GET` | `/version` | Which version is deployed? |
| `GET` | `/items` | List all items |
| `POST` | `/items` | Create an item: `{"name": "..."}` |
| `GET` | `/items/{id}` | Get one item |

The stack:

- **[Axum](https://github.com/tokio-rs/axum)**, a web framework from the Tokio team.
- **[sqlx](https://github.com/launchbadge/sqlx)**, an async PostgreSQL client with
  built-in migrations.
- **[tracing](https://github.com/tokio-rs/tracing)** for structured JSON logs.

## Step 1: Create the project

```bash
cargo new rust-devops-app
cd rust-devops-app
mkdir migrations tests
```

Replace `Cargo.toml` with:

```toml
[package]
name = "rust-devops-app"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.8"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sqlx = { version = "0.8", default-features = false, features = ["runtime-tokio", "tls-rustls", "postgres", "macros", "migrate"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }

[dev-dependencies]
tower = { version = "0.5", features = ["util"] }
http-body-util = "0.1"

[profile.release]
strip = true
lto = "thin"
```

A few choices worth noting:

- **`default-features = false` for sqlx** keeps only what we need. The
  `tls-rustls` feature gives us TLS without depending on OpenSSL, which makes
  the Docker image simpler and smaller later. It is also required for RDS,
  which only accepts encrypted connections.
- **`dev-dependencies`** are only compiled for tests: `tower` lets tests call the
  router directly, without starting a real HTTP server.
- **`[profile.release]`**: `strip` removes debug symbols and `lto = "thin"`
  enables link-time optimisation. Both make the release binary smaller.

## Step 2: The database migration

Create `migrations/0001_create_items.sql`:

```sql
CREATE TABLE IF NOT EXISTS items (
    id   BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL
);
```

sqlx runs migrations in order of their file names and records which ones have
already run in a table called `_sqlx_migrations`. You never edit a migration
after it has run somewhere; you add a new one instead.

## Step 3: The application (`src/lib.rs`)

The code is split into a **library** (`lib.rs`) and a small **binary**
(`main.rs`). The library contains the router and handlers. The binary only
reads configuration and starts the server. This split lets the tests in
`tests/` import the router and call it directly.

Create `src/lib.rs`:

```rust
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
}

#[derive(Serialize, sqlx::FromRow)]
pub struct Item {
    pub id: i64,
    pub name: String,
}

#[derive(Deserialize)]
pub struct NewItem {
    pub name: String,
}

pub fn app(state: AppState) -> Router {
    Router::new()
        // Liveness: the process is up. Used later by Kubernetes liveness probes.
        .route("/health", get(health))
        // Readiness: the process can reach the database.
        .route("/ready", get(ready))
        // Which version is running? Useful to verify deployments.
        .route("/version", get(version))
        .route("/items", get(list_items).post(create_item))
        .route("/items/{id}", get(get_item))
        .with_state(state)
}

async fn health() -> &'static str {
    "ok"
}

async fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

async fn ready(State(state): State<AppState>) -> StatusCode {
    match sqlx::query("SELECT 1").execute(&state.pool).await {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

async fn list_items(State(state): State<AppState>) -> Result<Json<Vec<Item>>, StatusCode> {
    sqlx::query_as::<_, Item>("SELECT id, name FROM items ORDER BY id")
        .fetch_all(&state.pool)
        .await
        .map(Json)
        .map_err(internal_error)
}

async fn get_item(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<Json<Item>, StatusCode> {
    sqlx::query_as::<_, Item>("SELECT id, name FROM items WHERE id = $1")
        .bind(id)
        .fetch_optional(&state.pool)
        .await
        .map_err(internal_error)?
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn create_item(
    State(state): State<AppState>,
    Json(input): Json<NewItem>,
) -> Result<(StatusCode, Json<Item>), StatusCode> {
    if input.name.trim().is_empty() {
        return Err(StatusCode::UNPROCESSABLE_ENTITY);
    }
    sqlx::query_as::<_, Item>("INSERT INTO items (name) VALUES ($1) RETURNING id, name")
        .bind(input.name.trim())
        .fetch_one(&state.pool)
        .await
        .map(|item| (StatusCode::CREATED, Json(item)))
        .map_err(internal_error)
}

fn internal_error(err: sqlx::Error) -> StatusCode {
    tracing::error!(error = %err, "database error");
    StatusCode::INTERNAL_SERVER_ERROR
}
```

How it fits together:

- **`AppState`** holds the database connection pool. Axum gives every handler
  access to it through `State(state)`. It derives `Clone` because Axum clones it
  for each request. That is cheap, because `PgPool` is internally reference-counted.
- **`Item` and `NewItem`** are the response and request bodies. `Serialize`,
  `Deserialize`, and `sqlx::FromRow` let serde and sqlx convert them to and
  from JSON and database rows automatically.
- **`app()`** builds the router. Note the path syntax `/items/{id}`: Axum 0.8 uses
  curly braces for path parameters.
- **Handlers return `Result<..., StatusCode>`.** A database error becomes a
  `500 Internal Server Error`, a missing item becomes `404 Not Found`, and an
  empty name becomes `422 Unprocessable Entity`.
- **`internal_error`** logs the real error but returns only a status code. The
  client never sees internal details like SQL errors, which is a basic security
  practice.
- **`env!("CARGO_PKG_VERSION")`** embeds the version from `Cargo.toml` at compile
  time. Later, this lets you check with one `curl` which version is actually
  running in the cluster.

### Why two health endpoints?

This distinction matters a great deal once the service runs on Kubernetes:

- **`/health` (liveness)** answers "is the process alive?" It deliberately does
  **not** check the database. If it fails, Kubernetes **restarts** the container.
- **`/ready` (readiness)** answers "can I handle requests right now?" It checks
  the database. If it fails, Kubernetes **stops sending traffic** to the pod,
  but does not restart it.

Imagine the database is unavailable for two minutes. If the liveness check
included the database, Kubernetes would restart every pod again and again, and
restarting does not fix a database. With separate endpoints, the pods simply
stop receiving traffic and recover by themselves when the database returns.
You will watch exactly this happen in the Kubernetes chapter.

## Step 4: The entry point (`src/main.rs`)

Replace `src/main.rs` with:

```rust
use rust_devops_app::{app, AppState};
use sqlx::postgres::PgPoolOptions;
use std::{env, time::Duration};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // JSON logs are easy to search later in CloudWatch or any log system.
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    // All config comes from environment variables (12-factor style).
    // Later, Kubernetes ConfigMaps/Secrets will provide these.
    let database_url = env::var("DATABASE_URL")?;
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await?;
    tracing::info!(%port, "server listening");

    axum::serve(listener, app(AppState { pool }))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

// Kubernetes sends SIGTERM before stopping a pod: finish in-flight requests first.
async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to listen for Ctrl+C");
    };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to listen for SIGTERM")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received");
}
```

Three production habits are built in here:

**1. Configuration from environment variables.** The database URL and port come
from `DATABASE_URL` and `PORT`. The same binary runs unchanged on your laptop,
in CI, in Docker, and in Kubernetes; only the environment differs. This is one
of the principles of the [twelve-factor app](https://12factor.net/config).

**2. Structured JSON logs.** Each log line is a JSON object, for example:

```json
{"timestamp":"...","level":"INFO","fields":{"message":"server listening","port":"8080"},"target":"rust_devops_app"}
```

Log systems such as CloudWatch can search and filter these by field. The log
level is controlled with the `RUST_LOG` environment variable, defaulting to `info`.

**3. Graceful shutdown.** When Kubernetes stops a pod, during a deployment for
example, it first sends the `SIGTERM` signal and waits before killing the process.
`with_graceful_shutdown` makes the server stop accepting new connections and
finish the requests already in progress. Without it, every deployment would cut
off some users mid-request.

`sqlx::migrate!("./migrations")` embeds the migration files into the binary at
compile time and runs any pending ones at startup. The Docker image therefore
does not need the `migrations` folder.

## Step 5: Tests (`tests/api.rs`)

Create `tests/api.rs`:

```rust
use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use rust_devops_app::{app, AppState};
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

/// Runs without a database: the pool is lazy and never connects.
#[tokio::test]
async fn health_returns_ok() {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://unused:unused@localhost/unused")
        .unwrap();
    let res = app(AppState { pool })
        .oneshot(Request::get("/health").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(res.status(), StatusCode::OK);
    let body = res.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(&body[..], b"ok");
}

/// Needs a real Postgres. Locally: `docker compose up -d db`.
/// In CI, the workflow starts Postgres as a service container.
/// Run with: cargo test -- --ignored
#[tokio::test]
#[ignore = "requires DATABASE_URL and a running Postgres"]
async fn create_and_fetch_item() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pool = PgPoolOptions::new().connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let router = app(AppState { pool });

    let res = router
        .clone()
        .oneshot(
            Request::post("/items")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"name":"first item"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let body = res.into_body().collect().await.unwrap().to_bytes();
    let created: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let id = created["id"].as_i64().unwrap();

    let res = router
        .oneshot(
            Request::get(format!("/items/{id}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
```

There are two kinds of tests here:

- **`health_returns_ok`** runs without a database. `connect_lazy` creates a pool
  that only connects when first used, and `/health` never uses it.
  `oneshot` sends a single request straight to the router, so no network or
  server is involved, and the test runs in milliseconds.
- **`create_and_fetch_item`** needs a real PostgreSQL. It is marked
  `#[ignore]`, so a plain `cargo test` skips it. In CI, a real database is
  available and the test runs with `--include-ignored`.

Why test against a real database at all? Because the SQL in this service is
written as plain strings. A typo in a column name or a wrong type compiles
fine and only fails at runtime. The integration test catches that before the
code is merged.

## Step 6: Run it locally

Start a throwaway PostgreSQL in Docker:

```bash
docker run --name devdb -d -p 5432:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app \
  postgres:16
```

Run all tests, including the database test:

```bash
export DATABASE_URL=postgres://app:app@localhost:5432/app
cargo test -- --include-ignored
```

You should see two passing tests. Now start the service:

```bash
cargo run
```

In a second terminal, try every endpoint:

```bash
curl localhost:8080/health; echo
curl -i localhost:8080/ready
curl localhost:8080/version; echo

curl -X POST localhost:8080/items \
  -H 'content-type: application/json' -d '{"name":"first item"}'; echo
curl localhost:8080/items; echo
curl localhost:8080/items/1; echo
curl -i localhost:8080/items/999
curl -i -X POST localhost:8080/items \
  -H 'content-type: application/json' -d '{"name":"   "}'
```

The last two should return `404 Not Found` and `422 Unprocessable Entity`.

Finally, test graceful shutdown: press `Ctrl+C` in the terminal running the
server. The last log line should be `shutdown signal received`.

Then test readiness: start the server again, stop the database with
`docker stop devdb`, and call both health endpoints:

```bash
curl -i localhost:8080/health   # still 200: the process is alive
curl -i localhost:8080/ready    # 503: the database is unreachable
```

Start the database again with `docker start devdb`, and `/ready` returns `200`
by itself. That is the liveness/readiness distinction in action.

Clean up when you are done:

```bash
docker rm -f devdb
```

## Troubleshooting

**`Error: environment variable not found` at startup.** `DATABASE_URL` is not
set in this terminal. Export it again; variables do not carry over to new
terminal windows.

**`Connection refused` or `error communicating with database`.** PostgreSQL is
not running or not ready yet. Check with `docker ps`, and wait a few seconds
after starting the container before running the service.

**`Address already in use`.** Something else is using port 8080, often a
previous `cargo run` that is still running. Stop it, or start the service on
another port with `PORT=8081 cargo run`.

**`password authentication failed for user "app"`.** The credentials in
`DATABASE_URL` do not match the container's `POSTGRES_USER` and
`POSTGRES_PASSWORD`. If you changed them, remove the container and start a new
one: PostgreSQL only reads these variables when it creates the database for
the first time.

## What you learned

- How to structure an Axum service as a library plus a small binary, so tests
  can call the router directly.
- How sqlx migrations are embedded in the binary and run at startup.
- Why liveness and readiness are separate endpoints, and what Kubernetes does
  differently for each.
- Three production habits: configuration from the environment, structured JSON
  logs, and graceful shutdown.
- The difference between fast unit tests and integration tests with a real database.

## Practice

1. Add a `DELETE /items/{id}` endpoint that returns `204 No Content` when an item
   was deleted and `404` when it did not exist. Write an integration test for it.
2. Add a `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` column with a **new**
   migration file, and include it in the JSON response. (Hint: the `chrono` or
   `time` feature of sqlx.)
3. Start the service with `RUST_LOG=debug cargo run` and compare the logs with
   the default level.
4. Change `/ready` so it also returns `503` while the server is shutting down.
   Think about why that could be useful during a Kubernetes deployment.

## Interview questions

- What is the difference between a liveness and a readiness probe, and what
  happens if you put a database check in the liveness probe?
- Why read configuration from environment variables instead of a config file
  baked into the build?
- What is graceful shutdown, and why does it matter for zero-downtime deployments?
- Why does the service return only a status code on database errors instead of
  the error message?
- What are the trade-offs between unit tests and integration tests against a
  real database?
