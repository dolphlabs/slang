use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const RESPONSE: &[u8] = b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";

async fn serve(mut sock: TcpStream) {
    let mut buf = [0u8; 2048];
    if sock.read(&mut buf).await.is_err() {
        return;
    }
    let _ = sock.write_all(RESPONSE).await;
}

#[tokio::main]
async fn main() {
    let port = std::env::var("HTTP_PORT").unwrap_or_else(|_| "18193".to_string());
    let listener = TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .expect("bind");
    println!("LISTEN_PORT {port}");
    loop {
        match listener.accept().await {
            Ok((sock, _)) => {
                tokio::spawn(serve(sock));
            }
            Err(_) => continue,
        }
    }
}
