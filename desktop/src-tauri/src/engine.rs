use crate::agent_llm::MiniAgent;
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

pub async fn run(
    app: AppHandle,
    store: Arc<Store>,
    mini: Arc<MiniAgent>,
) {
    // agent 事件通道（MiniAgent 流式输出 → 中继）
    let (agent_tx, agent_rx0) = mpsc::unbounded_channel::<Value>();
    let mut agent_rx: Option<mpsc::UnboundedReceiver<Value>> = Some(agent_rx0);
    let mut last_pair_poll = 0u64;
    let mut ws_sink: Option<WsSink> = None;
    let mut ws_reader: Option<mpsc::Receiver<Value>> = None;
    let mut ping_interval: Option<tokio::time::Interval> = None;
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
            emit_status(&app, &store, &mini, false).await;
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            continue;
        }

        // ---------- 设备在线阶段 ----------
        if s.paired() {
            // 断线时丢弃积压事件，防止内存膨胀
            if ws_sink.is_none() {
                if let Some(rx) = agent_rx.as_mut() {
                    while rx.try_recv().is_ok() {}
                }
                let url = format!("{}/ws/device?token={}", s.ws_base(), s.device_token);
                eprintln!("[engine] 尝试连接中继: {}", &url[..60.min(url.len())]);
                match tokio_tungstenite::connect_async(&url).await {
                    Ok((sock, _)) => {
                        eprintln!("[engine] WS 已建立");
                        let (sink, stream) = sock.split();
                        ws_sink = Some(sink);
                        // 读循环：中继 → 通道（忽略 Ping/Pong 等协议帧，仅 Text 转发）
                        let (tx_read, rx_read) = mpsc::channel::<Value>(64);
                        tokio::spawn(async move {
                            let mut stream = stream;
                            loop {
                                match stream.next().await {
                                    Some(Ok(WsMessage::Text(t))) => {
                                        if let Ok(v) = serde_json::from_str::<Value>(&t) {
                                            if tx_read.send(v).await.is_err() {
                                                break;
                                            }
                                        }
                                    }
                                    Some(Ok(_)) => {} // 协议帧（Ping/Pong/Binary），忽略
                                    _ => break,      // 关闭或错误
                                }
                            }
                        });
                        ws_reader = Some(rx_read);
                        ping_interval = Some(tokio::time::interval(std::time::Duration::from_secs(25)));
                        log_event(&app, "🟢 已连接中继");
                        emit_status(&app, &store, &mini, true).await;
                    }
                    Err(e) => {
                        eprintln!("[engine] WS 连接失败: {e}");
                        log_event(&app, format!("🔴 中继连接失败: {e}"));
                        emit_status(&app, &store, &mini, false).await;
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
                let ping_fut: std::pin::Pin<Box<dyn Future<Output = bool> + Send>> =
                    match ping_interval.as_mut() {
                        Some(iv) => Box::pin(async move {
                            iv.tick().await;
                            true
                        }),
                        None => Box::pin(std::future::pending()),
                    };
                tokio::select! {
                    msg = recv_relay => {
                        match msg {
                            Some(v) => handle_relay_msg(&app, sink, &v, &mini, &agent_tx).await,
                            None => disconnected = true,
                        }
                    }
                    ev = recv_agent => {
                        if let Some(ev) = ev {
                            // 按协议包装后转发（中继只认 {"type":"event","event":<原始事件>}）
                            let wrapped = json!({"type": "event", "event": ev});
                            let _ = sink.send(WsMessage::Text(serde_json::to_string(&wrapped).unwrap())).await;
                        }
                    }
                    _ = ping_fut => {
                        let _ = sink.send(WsMessage::Text(r#"{"type":"ping"}"#.into())).await;
                    }
                }
            }

            if disconnected {
                log_event(&app, "🔌 中继连接断开，重连中…");
                ws_sink = None;
                ws_reader = None;
                ping_interval = None;
                emit_status(&app, &store, &mini, false).await;
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
    mini: &Arc<MiniAgent>,
    agent_tx: &mpsc::UnboundedSender<Value>,
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
            let path_clean = path.split('?').next().unwrap_or(&path).to_string();
            log_event(
                app,
                format!(
                    "📨 收到指令 {method} {path_clean}",
                ),
            );

            let mini_c = Arc::clone(mini);
            let tx = agent_tx.clone();
            let id_task = id.clone();
            let method_task = method.clone();
            let path_task = path_clean.clone();
            let start = std::time::Instant::now();
            let reply = tokio::spawn(async move {
                let id = id_task;
                let data: Result<Value, String> =
                    dispatch(mini_c, &method_task, &path_task, body, tx);
                let mut out = json!({"type": "cmd.result", "id": id});
                match data {
                    Ok(d) => {
                        out["ok"] = Value::Bool(true);
                        out["data"] = d;
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
            let elapsed = start.elapsed().as_millis();
            let ok = reply.get("ok").and_then(|o| o.as_bool()).unwrap_or(false);
            let err = reply
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("");
            if ok {
                log_event(app, format!("✅ 指令完成 {method} {path_clean} ({elapsed}ms)"));
            } else {
                log_event(app, format!("❌ 指令失败 {method} {path_clean}: {err}"));
            }
            eprintln!("[engine] cmd {method} {path_clean} -> ok={ok} ({elapsed}ms) {err}");
            let _ = sink
                .send(WsMessage::Text(serde_json::to_string(&reply).unwrap()))
                .await;
        }
        _ => {}
    }
}

/// 指令分发：MiniAgent 实现 opencode 兼容指令面
fn dispatch(
    mini: Arc<MiniAgent>,
    method: &str,
    path: &str,
    body: Option<Value>,
    tx: mpsc::UnboundedSender<Value>,
) -> Result<Value, String> {
    let m = method.to_uppercase();
    let (m, path) = (m.as_str(), path.to_string());
    match (m, path.as_str()) {
        ("GET", "/global/health") => Ok(json!({
            "healthy": true,
            "version": format!("mini-agent (model: {})", mini.model_name()),
        })),
        ("GET", "/session") => Ok(mini.list_sessions()),
        ("POST", "/session") => {
            let title = body
                .as_ref()
                .and_then(|b| b.get("title"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            Ok(mini.create_session(&title))
        }
        ("GET", "/session/status") => Ok(mini.list_statuses()),
        _ if path.starts_with("/session/") && path.ends_with("/message") => {
            let sid = path
                .trim_start_matches("/session/")
                .trim_end_matches("/message");
            Ok(mini.get_messages(sid))
        }
        _ if path.starts_with("/session/") && path.ends_with("/prompt_async") => {
            let sid = path
                .trim_start_matches("/session/")
                .trim_end_matches("/prompt_async");
            let text = body
                .as_ref()
                .and_then(|b| b.get("parts"))
                .and_then(|p| p.as_array())
                .and_then(|a| a.first())
                .and_then(|p| p.get("text"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            mini.prompt(sid, &text, tx)?;
            Ok(Value::Null)
        }
        _ if path.starts_with("/session/") && path.ends_with("/abort") => {
            let sid = path.trim_start_matches("/session/").trim_end_matches("/abort");
            mini.abort(sid);
            Ok(Value::Bool(true))
        }
        _ => Err(format!("未知指令: {m} {path}")),
    }
}

pub async fn emit_status(
    app: &AppHandle,
    store: &Store,
    mini: &MiniAgent,
    online: bool,
) {
    let s = store.get();
    let _ = app.emit(
        "engine-status",
        json!({
            "loggedIn": !s.token.is_empty(),
            "paired": s.paired(),
            "pending": !s.pending_token.is_empty(),
            "online": online,
            "agentRunning": mini.configured(),
            "agentModel": mini.model_name(),
        }),
    );
}
