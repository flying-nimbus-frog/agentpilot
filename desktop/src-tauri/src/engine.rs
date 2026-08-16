use crate::agent::OpenCodeAgent;
use crate::agent_llm::MiniAgent;
use crate::relay;
use crate::store::Store;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::future::Future;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub const MODE_MINI: u8 = 0;
pub const MODE_OPENCODE: u8 = 1;

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsSink = futures_util::stream::SplitSink<WsStream, WsMessage>;

pub fn log_event(app: &AppHandle, line: impl AsRef<str>) {
    let line = line.as_ref().to_string();
    // 落盘日志（应用数据目录）
    if let Ok(dir) = app.path().app_log_dir() {
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("opencode-remote.log");
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(
                f,
                "{} {line}",
                chrono_like_now()
            );
        }
    }
    let _ = app.emit("log", line);
}

/// 简易时间戳（不引入 chrono 依赖）
fn chrono_like_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs() as i64;
    let (h, m, s) = ((secs % 86400) / 3600, (secs % 3600) / 60, secs % 60);
    format!("{:02}:{:02}:{:02}", h + 8, m, s)
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
    opencode: Arc<Mutex<OpenCodeAgent>>,
    mode: Arc<AtomicU8>,
) {
    // agent 事件通道（MiniAgent/opencode SSE → 中继）
    let (agent_tx, agent_rx0) = mpsc::unbounded_channel::<Value>();
    let mut agent_rx: Option<mpsc::UnboundedReceiver<Value>> = Some(agent_rx0);
    let mut sse_fwd: Option<tokio::task::JoinHandle<()>> = None;
    let mut last_pair_poll = 0u64;
    let mut ws_sink: Option<WsSink> = None;
    let mut ws_reader: Option<mpsc::Receiver<Value>> = None;
    let mut ping_interval: Option<tokio::time::Interval> = None;
    loop {
        let s = store.get();
        let base = s.http_base();

        // ---------- opencode 模式的 SSE 事件转发 ----------
        if mode.load(Ordering::Relaxed) == MODE_OPENCODE && sse_fwd.is_none() {
            let agent_c = Arc::clone(&opencode);
            let tx = agent_tx.clone();
            sse_fwd = Some(tokio::spawn(async move {
                loop {
                    let (port, password) = {
                        let a = agent_c.lock().await;
                        (a.port, a.password().to_string())
                    };
                    OpenCodeAgent::stream_events(port, password, tx.clone()).await;
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
            }));
        }
        if mode.load(Ordering::Relaxed) != MODE_OPENCODE {
            if let Some(t) = sse_fwd.take() {
                t.abort();
            }
        }

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
            emit_status(&app, &store, &mini, &opencode, &mode, false).await;
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
                        emit_status(&app, &store, &mini, &opencode, &mode, true).await;
                    }
                    Err(e) => {
                        eprintln!("[engine] WS 连接失败: {e}");
                        log_event(&app, format!("🔴 中继连接失败: {e}"));
                        emit_status(&app, &store, &mini, &opencode, &mode, false).await;
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
                            Some(v) => handle_relay_msg(&app, sink, &v, &mini, &opencode, &mode, &agent_tx).await,
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
                emit_status(&app, &store, &mini, &opencode, &mode, false).await;
            }
            // 无睡眠：select! 本身会挂起等待事件，保证流式事件零节流
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
    opencode: &Arc<Mutex<OpenCodeAgent>>,
    mode: &Arc<AtomicU8>,
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
            let opencode_c = Arc::clone(opencode);
            let mode_v = mode.load(Ordering::Relaxed);
            let tx = agent_tx.clone();
            let id_task = id.clone();
            let method_task = method.clone();
            let path_task = path_clean.clone();
            let start = std::time::Instant::now();
            let reply = tokio::spawn(async move {
                let id = id_task;
                let data: Result<Value, String> = if mode_v == MODE_OPENCODE {
                    let body = inject_concise(&method_task, &path_task, body);
                    opencode_request(&opencode_c, &method_task, &path_task, body).await
                } else {
                    dispatch(mini_c, &method_task, &path_task, body, tx)
                };
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

/// opencode 模式的手机端精简指令：注入 prompt_async 的 system 字段（不污染用户可见消息）。
fn inject_concise(method: &str, path: &str, body: Option<Value>) -> Option<Value> {
    if method != "POST" || !path.ends_with("/prompt_async") {
        return body;
    }
    let mut body = body?;
    const CONCISE: &str = "你是在手机上运行的助手，用户通过小屏手机阅读你的回复。请务必精简：\
优先直接给结论，去除铺垫、客套和冗余说明。除非用户明确要求详细，否则控制在 3-5 句话以内；\
需要代码时只给关键片段，不要逐行解释。不要复述用户的问题，不要总结你做了什么。";
    if body.get("system").is_none() {
        body["system"] = Value::String(CONCISE.to_string());
    }
    Some(body)
}

/// 指令分发：MiniAgent 实现 opencode 兼容指令面
fn dispatch(    mini: Arc<MiniAgent>,
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
    opencode: &Mutex<OpenCodeAgent>,
    mode: &AtomicU8,
    online: bool,
) {
    let s = store.get();
    let oc_running = opencode.lock().await.running();
    let m = mode.load(Ordering::Relaxed);
    let (running, model) = if m == MODE_OPENCODE {
        (oc_running, "opencode".to_string())
    } else {
        (mini.configured(), mini.model_name())
    };
    let _ = app.emit(
        "engine-status",
        json!({
            "loggedIn": !s.token.is_empty(),
            "paired": s.paired(),
            "pending": !s.pending_token.is_empty(),
            "online": online,
            "agentRunning": running,
            "agentModel": model,
        }),
    );
}

/// 指令转发到嵌入的 opencode 引擎
async fn opencode_request(
    opencode: &Mutex<OpenCodeAgent>,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> Result<Value, String> {
    let mut oc = opencode.lock().await;
    if !oc.running() {
        return Err("opencode 未启动".into());
    }
    let r = oc.request(method, path, body).await?;
    if r.get("ok").and_then(|o| o.as_bool()).unwrap_or(false) {
        Ok(r.get("data").cloned().unwrap_or(Value::Null))
    } else {
        Err(r
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("opencode 指令失败")
            .to_string())
    }
}
