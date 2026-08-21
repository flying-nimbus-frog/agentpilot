//! 本地认证反向代理：把 127.0.0.1:{listen} 的 HTTP/SSE/WS 请求转发到
//! 127.0.0.1:{upstream} 的 opencode serve，并自动注入 Basic 认证。
//! 用途：桌面端 WebView / 手机端中继直接内嵌 opencode 原生界面，无需浏览器弹认证框。
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

const MAX_HEAD: usize = 16 * 1024;

/// 启动反代监听。返回 JoinHandle。
pub fn spawn(upstream_port: u16, password: String, listen_port: u16) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let listener = match TcpListener::bind(("127.0.0.1", listen_port)).await {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[proxy] 监听 {listen_port} 失败: {e}");
                return;
            }
        };
        let auth = format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode(format!("opencode:{password}"))
        );
        while let Ok((sock, _)) = listener.accept().await {
            let auth = auth.clone();
            tokio::spawn(async move {
                if let Err(e) = handle(sock, upstream_port, auth).await {
                    eprintln!("[proxy] 转发失败: {e}");
                }
            });
        }
    })
}

/// 探测本进程自己的反代是否已绑定指定端口。
pub async fn is_bound(port: u16) -> bool {
    use tokio::net::TcpStream;
    matches!(TcpStream::connect(("127.0.0.1", port)).await, Ok(_))
}

fn split_head(buf: &[u8]) -> Option<(&[u8], usize)> {
    let mut i = 0;
    while i + 3 < buf.len() {
        if &buf[i..i + 4] == b"\r\n\r\n" {
            return Some((&buf[..i + 4], i + 4));
        }
        i += 1;
    }
    None
}

fn head_is_ws(head: &[u8]) -> bool {
    let s = String::from_utf8_lossy(head);
    s.to_ascii_lowercase().contains("upgrade: websocket")
}

async fn handle(sock: TcpStream, upstream_port: u16, auth: String) -> Result<(), Box<dyn std::error::Error>> {
    let mut sock = sock;
    let mut head = Vec::with_capacity(MAX_HEAD);
    let mut buf = [0u8; 8192];
    let head_end = loop {
        let n = sock.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
        if head.len() > MAX_HEAD {
            return Err("请求头过大".into());
        }
        if let Some((_, end)) = split_head(&head) {
            break end;
        }
    };
    let consumed = head_end;
    if head_is_ws(&head) {
        return ws_tunnel(sock, head, upstream_port, auth).await;
    }
    http_fwd(sock, &head[..consumed], upstream_port, auth).await
}

// ---------- HTTP 转发（含 SSE 流式，reqwest 无缓冲逐块回写） ----------
async fn http_fwd(
    mut sock: TcpStream,
    head: &[u8],
    upstream_port: u16,
    auth: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let head_str = String::from_utf8_lossy(head).to_string();
    let mut lines = head_str.lines();
    let req_line = lines.next().unwrap_or("").to_string();
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut skip_conn = false;
    for line in lines.by_ref() {
        let l = line.trim_end_matches('\r');
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            let k = k.trim().to_lowercase();
            let v = v.trim().to_string();
            if k == "host" || k == "connection" {
                skip_conn = true;
                continue;
            }
            if k == "content-length" || k == "transfer-encoding" || k == "accept-encoding" {
                continue;
            }
            headers.push((k, v));
        }
    }
    // 请求体（Content-Length 形式）
    let body = if let Some(v) = headers.iter().find(|(k, _)| k == "content-length") {
        let n: usize = v.1.parse().unwrap_or(0);
        if n > 0 {
            let mut b = vec![0u8; n];
            let mut got = 0;
            while got < n {
                let r = sock.read(&mut b[got..]).await?;
                if r == 0 {
                    break;
                }
                got += r;
            }
            b.truncate(got);
            Some(b)
        } else {
            None
        }
    } else {
        None
    };
    let url = format!("http://127.0.0.1:{upstream_port}{target}");
    let client = reqwest::Client::new();
    let mut req = client
        .request(reqwest::Method::from_bytes(method.as_bytes()).unwrap_or(reqwest::Method::GET), &url)
        .header("Authorization", auth);
    for (k, v) in &headers {
        req = req.header(k, v);
    }
    let resp = if let Some(b) = body {
        req.body(b).send().await
    } else {
        req.send().await
    };
    let resp = resp?;
    let status = resp.status();
    let mut out = format!("HTTP/1.1 {status} {}\r\n", status.canonical_reason().unwrap_or(""));
    let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    if !ct.is_empty() {
        out.push_str(&format!("content-type: {ct}\r\n"));
    }
    if let Some(cl) = resp.content_length() {
        if cl > 0 && skip_conn {
            out.push_str(&format!("content-length: {cl}\r\n"));
        }
    }
    if !skip_conn {
        out.push_str("connection: keep-alive\r\n");
    }
    out.push_str("\r\n");
    sock.write_all(out.as_bytes()).await?;
    let mut stream = Box::pin(resp.bytes_stream());
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        sock.write_all(&chunk).await?;
    }
    Ok(())
}

// ---------- WebSocket 双向隧道（/pty/*/connect 等） ----------
struct PrefixedStream {
    rest: Vec<u8>,
    pos: usize,
    inner: TcpStream,
}

impl AsyncRead for PrefixedStream {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, out: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        if self.pos < self.rest.len() {
            let n = std::cmp::min(out.remaining(), self.rest.len() - self.pos);
            out.put_slice(&self.rest[self.pos..self.pos + n]);
            self.pos += n;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_read(cx, out)
    }
}

impl AsyncWrite for PrefixedStream {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

async fn ws_tunnel(
    sock: TcpStream,
    head: Vec<u8>,
    upstream_port: u16,
    auth: String,
) -> Result<(), Box<dyn std::error::Error>> {
    // 从已读头部里还原目标路径
    let head_str = String::from_utf8_lossy(&head);
    let req_line = head_str.lines().next().unwrap_or("").to_string();
    let mut parts = req_line.split_whitespace();
    let _method = parts.next().unwrap_or("GET");
    let target = parts.next().unwrap_or("/");
    let url = format!("ws://127.0.0.1:{upstream_port}{target}");
    let mut ws = {
        let prefixed = PrefixedStream { rest: head, pos: 0, inner: sock };
        tokio_tungstenite::accept_async(prefixed).await?
    };
    let mut upstream = {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let mut req = url.into_client_request()?;
        let h = req.headers_mut();
        h.insert("Authorization", auth.parse()?);
        let (stream, _resp) = tokio_tungstenite::connect_async(req).await?;
        stream
    };
    // 双向泵
    loop {
        tokio::select! {
            m = ws.next() => {
                match m {
                    Some(Ok(msg)) => {
                        let payload = match msg {
                            Message::Binary(b) => b,
                            Message::Text(t) => t.into_bytes(),
                            Message::Ping(p) => { upstream.send(Message::Ping(p)).await?; continue; }
                            Message::Close(_) => { let _ = upstream.close(None).await; return Ok(()); }
                            _ => continue,
                        };
                        upstream.send(Message::Binary(payload)).await?;
                    }
                    Some(Err(_)) | None => return Ok(()),
                }
            }
            m = upstream.next() => {
                match m {
                    Some(Ok(msg)) => {
                        let payload = match msg {
                            Message::Binary(b) => b,
                            Message::Text(t) => t.into_bytes(),
                            Message::Ping(p) => { ws.send(Message::Ping(p)).await?; continue; }
                            Message::Close(_) => { let _ = ws.close(None).await; return Ok(()); }
                            _ => continue,
                        };
                        ws.send(Message::Binary(payload)).await?;
                    }
                    Some(Err(_)) | None => return Ok(()),
                }
            }
        }
    }
}