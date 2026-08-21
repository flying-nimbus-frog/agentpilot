use std::sync::atomic::{AtomicUsize, Ordering};

// 启动一个极简上游 HTTP+WS 服务器(纯 tokio)
fn spawn_upstream(port: u16) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.unwrap();
        loop {
            let (mut sock, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]);
                // 校验认证
                if !req.to_lowercase().contains("authorization: basic ") && !req.to_lowercase().contains("upgrade") {
                    let _ = sock.write_all(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n").await;
                    return;
                }
                let is_ws = req.to_lowercase().contains("upgrade: websocket");
                if is_ws {
                    // 简易 WS 应答：直接回 101 并保持 (冒烟只验证 HTTP)
                    let _ = sock.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").await;
                    return;
                }
                let body = b"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello";
                let _ = sock.write_all(body).await;
            });
        }
    })
}

#[tokio::test]
async fn proxy_forwards_http_with_auth() {
    // 并发跑两次测试会抢端口；用固定端口+跳过重复
    static LOCK: AtomicUsize = AtomicUsize::new(0);
    if LOCK.fetch_add(1, Ordering::SeqCst) != 0 { return; }
    spawn_upstream(49150);
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    desktop_lib::proxy::spawn(49150, "secret".into(), 49151);
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    // 无认证时上游代理应已注入
    let resp = reqwest::get("http://127.0.0.1:49151/").await.unwrap();
    assert_eq!(resp.status(), 200);
    let body = resp.text().await.unwrap();
    assert_eq!(body, "hello");
}

#[tokio::test]
async fn proxy_401_without_injection_is_handled_by_upstream_auth() {
    static LOCK: AtomicUsize = AtomicUsize::new(0);
    if LOCK.fetch_add(1, Ordering::SeqCst) != 0 { return; }
    // 上游严格要求认证但我们的代理注入了，因此返回200
    spawn_upstream(49152);
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    desktop_lib::proxy::spawn(49152, "secret".into(), 49153);
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let resp = reqwest::get("http://127.0.0.1:49153/").await.unwrap();
    assert!(resp.status().is_success());
}
