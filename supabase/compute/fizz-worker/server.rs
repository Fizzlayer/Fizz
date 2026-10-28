use std::{
    env,
    io::{Read, Write},
    net::TcpListener,
    time::Duration,
};

fn main() -> std::io::Result<()> {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_owned());
    let listener = TcpListener::bind(format!("0.0.0.0:{port}"))?;
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else {
            continue;
        };
        // A stalled or disconnected health-check client must not stop the worker.
        if stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .is_err()
            || stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .is_err()
        {
            continue;
        }
        let mut request = [0_u8; 1024];
        let Ok(bytes) = stream.read(&mut request) else {
            continue;
        };
        let healthy = request[..bytes].starts_with(b"GET /health ");
        let (status, body) = if healthy {
            ("200 OK", r#"{"service":"fizz-worker","status":"ok"}"#)
        } else {
            ("404 Not Found", r#"{"error":"not_found"}"#)
        };
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
    }
    Ok(())
}
