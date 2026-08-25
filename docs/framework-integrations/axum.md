# Joubako with Axum

This integration connects Joubako to an Axum service running on Tokio. Axum's
typed extractors and Serde models interoperate with the same JSON schema used by
the Nim client.

## Backend implementation

```rust
#[derive(Deserialize, Serialize)]
struct MessageRequest {
    text: String,
    priority: i32,
}

async fn message(headers: HeaderMap, Json(request): Json<MessageRequest>) -> Response {
    if request.text.is_empty() || !(1..=5).contains(&request.priority) {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error": "invalid message"})),
        ).into_response();
    }

    (
        StatusCode::CREATED,
        Json(json!({
            "accepted": true,
            "text": request.text,
            "priority": request.priority,
            "framework": "Axum",
        })),
    ).into_response()
}
```

See the complete [`main.rs`](../../examples/frameworks/axum/src/main.rs).

## Run Axum

```sh
cd examples/frameworks/axum
cargo run --release --locked
```

## Call Axum from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8084/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Axum \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The integration is built and executed in CI with both ARC and ORC Joubako
clients.

## Production notes

Add bounded body extractors, authentication layers, tracing, timeouts, and
concurrency limits through the service's Tower stack. Coordinate those limits
with Joubako's client deadlines and maximum response sizes.
