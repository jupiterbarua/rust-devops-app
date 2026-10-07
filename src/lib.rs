use std::time::Instant;

use axum::{
    extract::{MatchedPath, Path, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    routing::get,
    Json, Router,
};
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub metrics: PrometheusHandle,
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

/// Latency buckets in seconds for the request duration histogram.
const LATENCY_BUCKETS: &[f64] = &[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0];

/// Install the global Prometheus recorder. Call once at startup.
pub fn install_metrics() -> PrometheusHandle {
    PrometheusBuilder::new()
        .set_buckets_for_metric(
            Matcher::Full("http_request_duration_seconds".to_string()),
            LATENCY_BUCKETS,
        )
        .expect("valid histogram buckets")
        .install_recorder()
        .expect("failed to install Prometheus recorder")
}

pub fn app(state: AppState) -> Router {
    Router::new()
        // Liveness: the process is up. Used later by Kubernetes liveness probes.
        .route("/health", get(health))
        // Readiness: the process can reach the database.
        .route("/ready", get(ready))
        .route("/items", get(list_items).post(create_item))
        .route("/items/{id}", get(get_item))
        .route_layer(middleware::from_fn(track_metrics)) // measures routes above
        .route("/metrics", get(metrics_handler)) // not measured
        .route("/version", get(version))
        .with_state(state)
}

/// Records a request counter and a latency histogram for every request.
async fn track_metrics(req: Request, next: Next) -> Response {
    let start = Instant::now();

    // The route pattern (e.g. "/items/{id}"), not the raw URL ("/items/42"),
    // so the number of label values stays small.
    let path = req
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());
    let method = req.method().to_string();

    let response = next.run(req).await;

    let labels = [
        ("method", method),
        ("path", path),
        ("status", response.status().as_u16().to_string()),
    ];
    metrics::counter!("http_requests_total", &labels).increment(1);
    metrics::histogram!("http_request_duration_seconds", &labels)
        .record(start.elapsed().as_secs_f64());

    response
}

async fn metrics_handler(State(state): State<AppState>) -> String {
    state.metrics.render()
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
    metrics::counter!("database_errors_total").increment(1);
    StatusCode::INTERNAL_SERVER_ERROR
}
