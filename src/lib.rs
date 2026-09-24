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
        .route("/items", get(list_items).post(create_item))
        .route("/items/{id}", get(get_item))
        .with_state(state)
}

async fn health() -> &'static str {
    "ok"
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
