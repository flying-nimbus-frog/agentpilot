use crate::agent::OpenCodeAgent;
use crate::relay;
use crate::store::Store;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::future::Future;
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsSink = futures_util::stream::SplitSink<WsStream, WsMessage>;

pub fn log_event(app: &AppHandle, line: impl AsRef<str>) {
    let _ = app.emit("log", line.as_ref().to_string());
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub async fn run(app: AppHandle, store: Arc<Store>, agent: Arc<Mutex<OpenCodeAgent>>) {
    let mut last_pair_poll = 0u64;
    let mut ws_sink: Option<WsSink> = None;
    let mut ws_reader: Option<mpsc::Receiver<Value>> = None;
    let mut agent_rx: Option<mpsc::UnboundedReceiver<Value>> = None;
    let mut sse_task: Option<tokio::task::JoinHandle<()>> = None;
    loop {
        let s = store.get();
        let base = s.http_base();

        // ---------- 配对阶段 ----------
        if !s.paired() && !s.pending_token.is_empty() && !s.pending_id.is_empty() {
            if now_secs().saturating_sub(last_pair_poll) >= 3 {
                last_pair_poll = now_secs();
                match relay::pair_status(&base, &s.pending_id, &s.pending_token).await {
                    Ok(ps) if ps.status == "active" => {
                        if let Some(dt) = ps.device_token {
                            log_event(&app, "✅ 配对成功，设备已激活");
                            store.update(|cfg| {
                                cfg.device_token = dt;
                                cfg.pending_id.clear();
                                cfg.pending_token.clear();
                            });
                        }
                    }
                    Ok(_) => {}
                    Err(e) => {
                        if e.contains("过期") {
                            log_event(&app, format!("⚠️ 配对码已过期: {e}，请重新注册设备"));
                            store.update(|cfg| {
                                cfg.pending_id.clear();
                                cfg.pending_token.clear();
                            });
                        }
                    }
                }
            }
            emit_status(&app, &store, &agent, false);
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            continue;
        }

        // ---------- 设备在线阶段 ----------
        if s.paired() {
            if sse_task.is_none() {
                let (tx, rx) = mpsc::unbounded_channel();
                let agent_c = Arc::clone(&agent);
                sse_task = Some(tokio::spawn(async move {
                    loop {
                        let (port, password) = {
                            let a = agent_c.lock().await;
                            (a.port, a.password().to_string())
                        };
                        OpenCodeAgent::stream_events(port, password, tx.clone()).await;
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    }
                }));
                agent_rx = Some(rx);
            }

            // 断线时丢弃积压事件，防止内存膨胀
            if ws_sink.is_none() {
                if let Some(rx) = agent_rx.as_mut() {
                    while rx.try_recv().is_ok() {}
                }
                let url = format!("{}/ws/device?token={}", s.ws_base(), s.device_token);
                match tokio_tungstenite::connect_async(&url).await {
                    Ok((sock, _)) => {
                        let (sink, stream) = sock.split();
                        ws_sink = Some(sink);
                        // 读循环：中继 → 通道
                        let (tx_read, rx_read) = mpsc::channel::<Value>(64);
                        tokio::spawn(async move {
                            let mut stream = stream;
                            while let Some(Ok(WsMessage::Text(t))) = stream.next().await {
                                if let Ok(v) = serde_json::from_str::<Value>(&t) {
                                    if tx_read.send(v).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        });
                        ws_reader = Some(rx_read);
                        log_event(&app, "🟢 已连接中继");
                        emit_status(&app, &store, &agent, true);
                    }
                    Err(e) => {
                        log_event(&app, format!("🔴 中继连接失败: {e}"));
                        emit_status(&app, &store, &agent, false);
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                        continue;
                    }
                }
            }

            let mut disconnected = false;
            if let Some(sink) = ws_sink.as_mut() {
                let recv_relay: std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send>> =
                    match ws_reader.as_mut() {
                        Some(rx) => Box::pin(rx.recv()),
                        None => Box::pin(std::future::ready(None)),
                    };
                let recv_agent: std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send>> =
                    match agent_rx.as_mut() {
                        Some(rx) => Box::pin(rx.recv()),
                        None => Box::pin(std::future::ready(None)),
                    };
                tokio::select! {
                    msg = recv_relay => {
                        match msg {
                            Some(v) => handle_relay_msg(&app, sink, &v, &agent).await,
                            None => disconnected = true,
                        }
                    }
                    ev = recv_agent => {
                        if let Some(ev) = ev {
                            let _ = sink.send(WsMessage::Text(serde_json::to_string(&ev).unwrap())).await;
                        }
                    }
                }
            }

            if disconnected {
                log_event(&app, "🔌 中继连接断开，重连中…");
                ws_sink = None;
                ws_reader = None;
                emit_status(&app, &store, &agent, false);
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            continue;
        }

        // ---------- 未登录/未注册 ----------
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}

async fn handle_relay_msg(
    app: &AppHandle,
    sink: &mut WsSink,
    msg: &Value,
    agent: &Arc<Mutex<OpenCodeAgent>>,
) {
    let t = msg.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match t {
        "ping" => {
            let _ = sink
                .send(WsMessage::Text(r#"{"type":"pong"}"#.into()))
                .await;
        }
        "cmd" => {
            let id = msg.get("id").cloned().unwrap_or(Value::Null);
            let inner = msg.get("cmd").cloned().unwrap_or(Value::Null);
            log_event(
                app,
                format!(
                    "📨 收到指令 {} {}",
                    inner.get("method").and_then(|m| m.as_str()).unwrap_or("?"),
                    inner.get("path").and_then(|p| p.as_str()).unwrap_or("")
                ),
            );
            let agent_c = Arc::clone(agent);
            let id_task = id.clone();
            let reply = tokio::spawn(async move {
                let id = id_task;
                let method = inner
                    .get("method")
                    .and_then(|m| m.as_str())
                    .unwrap_or("GET")
                    .to_string();
                let path = inner
                    .get("path")
                    .and_then(|p| p.as_str())
                    .unwrap_or("/")
                    .to_string();
                let body = inner.get("body").cloned();
                let mut a = agent_c.lock().await;
                let result = if a.running() {
                    a.request(&method, &path, body).await
                } else {
                    Err("Agent 未启动".into())
                };
                let mut out = json!({"type": "cmd.result", "id": id});
                match result {
                    Ok(r) => {
                        out["ok"] = r.get("ok").cloned().unwrap_or(Value::Bool(false));
                        if let Some(d) = r.get("data") {
                            out["data"] = d.clone();
                        }
                        if let Some(e) = r.get("error") {
                            out["error"] = e.clone();
                        }
                    }
                    Err(e) => {
                        out["ok"] = Value::Bool(false);
                        out["error"] = Value::String(e);
                    }
                }
                out
            })
            .await
            .unwrap_or(json!({"type": "cmd.result", "id": id, "ok": false, "error": "内部错误"}));
            let _ = sink
                .send(WsMessage::Text(serde_json::to_string(&reply).unwrap()))
                .await;
        }
        _ => {}
    }
}

pub async fn emit_status(
    app: &AppHandle,
    store: &Store,
    agent: &Mutex<OpenCodeAgent>,
    online: bool,
) {
    let s = store.get();
    let mut a = agent.lock().await;
    let _ = app.emit(
        "engine-status",
        json!({
            "loggedIn": !s.token.is_empty(),
            "paired": s.paired(),
            "pending": !s.pending_token.is_empty(),
            "online": online,
            "agentRunning": a.running(),
            "agentPath": crate::agent::detect(),
        }),
    );
}
