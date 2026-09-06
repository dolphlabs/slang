use axum::{http::header, response::IntoResponse, routing::get, Router};

const BODY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";

async fn hello() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/plain"),
            (header::CONNECTION, "close"),
        ],
        BODY,
    )
}

#[tokio::main]
async fn main() {
    let port = std::env::var("HTTP_PORT").unwrap_or_else(|_| "18183".to_string());
    let app = Router::new().route("/", get(hello));
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .expect("bind");
    println!("LISTEN_PORT {port}");
    axum::serve(listener, app).await.expect("serve");
}
