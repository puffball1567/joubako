use std::env;

use axum::{
    extract::Path,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::net::TcpListener;

#[derive(Serialize)]
struct HealthResponse {
    ok: bool,
    framework: &'static str,
}

#[derive(Serialize)]
struct UserResponse {
    id: u64,
    name: &'static str,
    email: &'static str,
}

#[derive(Deserialize, Serialize)]
struct MessageRequest {
    text: String,
    priority: i32,
}

#[derive(Serialize)]
struct MessageResponse {
    accepted: bool,
    text: String,
    priority: i32,
    framework: &'static str,
    client: String,
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        framework: "Axum",
    })
}

async fn user(Path(id): Path<u64>) -> Response {
    if id != 1 {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"error": "user not found"})),
        )
            .into_response();
    }

    Json(UserResponse {
        id,
        name: "Axum User",
        email: "axum@example.test",
    })
    .into_response()
}

async fn message(headers: HeaderMap, Json(request): Json<MessageRequest>) -> Response {
    if request.text.is_empty() || request.text.len() > 200 || !(1..=5).contains(&request.priority) {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error": "invalid message"})),
        )
            .into_response();
    }

    let client = headers
        .get("x-joubako-demo")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("unknown")
        .to_owned();

    (
        StatusCode::CREATED,
        Json(MessageResponse {
            accepted: true,
            text: request.text,
            priority: request.priority,
            framework: "Axum",
            client,
        }),
    )
        .into_response()
}

#[tokio::main]
async fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8084".to_owned());
    let listener = TcpListener::bind(format!("127.0.0.1:{port}"))
        .await
        .expect("failed to bind Axum demo server");

    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/users/{id}", get(user))
        .route("/api/messages", post(message));

    axum::serve(listener, app)
        .await
        .expect("Axum demo server failed");
}
