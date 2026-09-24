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
