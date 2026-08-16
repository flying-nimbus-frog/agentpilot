/// 内置 MiniAgent：进程内直连 LLM（OpenAI 兼容接口），
/// 对外提供与 opencode 兼容的指令面（/session, prompt_async, abort），手机端零改动。
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// 手机端输出风格约束：默认精炼，避免长篇大论。
const CONCISE_PROMPT: &str = "你是在手机上运行的助手，用户通过小屏手机阅读你的回复。请务必精简：\
优先直接给结论，去除铺垫、客套和冗余说明。除非用户明确要求详细，否则控制在 3-5 句话以内；\
需要代码时只给关键片段，不要逐行解释。不要复述用户的问题，不要总结你做了什么。";

#[derive(Clone)]
pub struct MiniMsg {
    pub id: String,
    pub role: String,
    pub text: String,
    pub created: u64,
}

#[derive(Clone)]
pub struct MiniSession {
    pub id: String,
    pub title: String,
    pub messages: Vec<MiniMsg>,
    pub created: u64,
    pub updated: u64,
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub struct MiniAgent {
    sessions: Mutex<HashMap<String, MiniSession>>,
    api_base: Mutex<String>,
    api_key: Mutex<String>,
    model: Mutex<String>,
    streaming: Mutex<Option<String>>,
    abort: Mutex<bool>,
    seq: AtomicU64,
}

impl MiniAgent {
    pub fn new() -> Arc<Self> {
        Arc::new(MiniAgent {
            sessions: Mutex::new(HashMap::new()),
            api_base: Mutex::new("https://api.deepseek.com".into()),
            api_key: Mutex::new(String::new()),
            model: Mutex::new("deepseek-v4-flash".into()),
            streaming: Mutex::new(None),
            abort: Mutex::new(false),
            seq: AtomicU64::new(0),
        })
    }

    fn next_id(&self, prefix: &str) -> String {
        let n = self.seq.fetch_add(1, Ordering::Relaxed);
        format!("{prefix}{:08x}", n + 1)
    }

    pub fn configure(&self, api_base: &str, api_key: &str, model: &str) {
        if !api_base.trim().is_empty() {
            *self.api_base.lock().unwrap() = api_base.trim().trim_end_matches('/').to_string();
        }
        *self.api_key.lock().unwrap() = api_key.trim().to_string();
        if !model.trim().is_empty() {
            *self.model.lock().unwrap() = model.trim().to_string();
        }
    }

    pub fn configured(&self) -> bool {
        !self.api_key.lock().unwrap().is_empty()
    }

    pub fn running(&self) -> bool {
        self.streaming.lock().unwrap().is_some()
    }

    pub fn model_name(&self) -> String {
        self.model.lock().unwrap().clone()
    }

    // ---------- 指令面（opencode 兼容） ----------

    pub fn list_sessions(&self) -> Value {
        let sessions = self.sessions.lock().unwrap();
        let model = self.model.lock().unwrap().clone();
        let mut list: Vec<Value> = sessions
            .values()
            .map(|s| {
                json!({
                    "id": s.id,
                    "title": s.title,
                    "directory": "内置 MiniAgent",
                    "time": {"created": s.created, "updated": s.updated},
                    "type": "chat",
                    "agent": "mini",
                    "model": model,
                })
            })
            .collect();
        list.sort_by(|a, b| {
            b["time"]["updated"]
                .as_u64()
                .unwrap_or(0)
                .cmp(&a["time"]["updated"].as_u64().unwrap_or(0))
        });
        Value::Array(list)
    }

    pub fn create_session(&self, title: &str) -> Value {
        let id = self.next_id("ses_mini");
        let t = now();
        let title = if title.trim().is_empty() {
            format!("MiniAgent {}", &id[7..])
        } else {
            title.to_string()
        };
        let mut sessions = self.sessions.lock().unwrap();
        sessions.insert(
            id.clone(),
            MiniSession {
                id: id.clone(),
                title,
                messages: vec![],
                created: t,
                updated: t,
            },
        );
        let s = sessions.get(&id).unwrap();
        json!({
            "id": s.id,
            "title": s.title,
            "directory": "内置 MiniAgent",
            "time": {"created": s.created, "updated": s.updated},
            "type": "chat",
        })
    }

    pub fn get_messages(&self, session_id: &str) -> Value {
        let sessions = self.sessions.lock().unwrap();
        let Some(s) = sessions.get(session_id) else {
            return Value::Array(vec![]);
        };
        let out: Vec<Value> = s
            .messages
            .iter()
            .map(|m| {
                json!({
                    "info": {
                        "id": m.id,
                        "role": m.role,
                        "sessionID": session_id,
                        "time": {"created": m.created},
                    },
                    "parts": [{"id": format!("prt_{}", m.id), "type": "text", "text": m.text}],
                })
            })
            .collect();
        Value::Array(out)
    }

    /// 运行状态（opencode /session/status 兼容：sessionID -> {type}）
    pub fn list_statuses(&self) -> Value {
        let mut out = serde_json::Map::new();
        let streaming = self.streaming.lock().unwrap().clone();
        if let Some(sid) = streaming {
            out.insert(sid, json!({"type": "busy"}));
        }
        Value::Object(out)
    }

    pub fn abort(&self, session_id: &str) {
        let mut streaming = self.streaming.lock().unwrap();
        if streaming.as_deref() == Some(session_id) {
            *self.abort.lock().unwrap() = true;
            *streaming = None;
        }
    }

    /// 发起流式对话（prompt_async 语义：立即返回，内容走事件）
    pub fn prompt(
        self: &Arc<Self>,
        session_id: &str,
        text: &str,
        tx: mpsc::UnboundedSender<Value>,
    ) -> Result<(), String> {
        {
            let mut sessions = self.sessions.lock().unwrap();
            let Some(s) = sessions.get_mut(session_id) else {
                return Err(format!("会话不存在: {session_id}"));
            };
            s.messages.push(MiniMsg {
                id: self.next_id("msg_mini"),
                role: "user".into(),
                text: text.to_string(),
                created: now(),
            });
            s.updated = now();
        }
        {
            let mut streaming = self.streaming.lock().unwrap();
            if streaming.is_some() {
                return Err("已有任务在运行".into());
            }
            *streaming = Some(session_id.to_string());
            *self.abort.lock().unwrap() = false;
        }
        let me = Arc::clone(self);
        let session_id = session_id.to_string();
        let text = text.to_string();
        tokio::spawn(async move {
            me.stream_loop(&session_id, &text, tx).await;
        });
        Ok(())
    }

    async fn stream_loop(
        self: Arc<Self>,
        session_id: &str,
        prompt: &str,
        tx: mpsc::UnboundedSender<Value>,
    ) {
        let api_base = self.api_base.lock().unwrap().clone();
        let api_key = self.api_key.lock().unwrap().clone();
        let model = self.model.lock().unwrap().clone();
        let assistant_id = self.next_id("msg_mini");
        let part_id = format!("prt_{assistant_id}");

        let ev = |t: &str, props: Value| json!({"type": t, "properties": props});
        let status = |s: &str| {
            ev(
                "session.status",
                json!({"sessionID": session_id, "status": {"type": s}}),
            )
        };

        // 回显用户消息（opencode 兼容：手机端靠事件渲染自己的输入）
        let user_msg_id = {
            let sessions = self.sessions.lock().unwrap();
            sessions
                .get(session_id)
                .and_then(|s| s.messages.last())
                .map(|m| m.id.clone())
                .unwrap_or_else(|| self.next_id("msg_mini"))
        };
        let user_part_id = format!("prt_{user_msg_id}");
        let _ = tx.send(ev(
            "message.created",
            json!({"sessionID": session_id, "messageID": user_msg_id}),
        ));
        let _ = tx.send(ev(
            "message.part.updated",
            json!({
                "sessionID": session_id,
                "part": {"id": user_part_id, "messageID": user_msg_id, "type": "text", "text": prompt}
            }),
        ));

        let _ = tx.send(status("busy"));
        let _ = tx.send(ev(
            "message.part.updated",
            json!({
                "sessionID": session_id,
                "part": {"id": part_id, "messageID": assistant_id, "type": "text", "text": ""}
            }),
        ));

        // 组装历史（前置系统指令：手机端精简输出）
        let history: Vec<Value> = {
            let mut msgs = vec![json!({"role": "system", "content": CONCISE_PROMPT})];
            let sessions = self.sessions.lock().unwrap();
            if let Some(s) = sessions.get(session_id) {
                msgs.extend(
                    s.messages
                        .iter()
                        .map(|m| json!({"role": m.role, "content": m.text})),
                );
            }
            msgs
        };

        let client = reqwest::Client::new();
        let url = format!("{api_base}/chat/completions");
        let body = json!({
            "model": model,
            "messages": history,
            "stream": true,
        });
        let t0 = std::time::Instant::now();
        eprintln!("[mini] 会话 {session_id} 对话开始 (model={model}, 输入 {} 字)", prompt.chars().count());
        let res = client
            .post(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await;

        let mut full = String::new();
        match res {
            Ok(res) if res.status().is_success() => {
                let stream = res.bytes_stream();
                let mut stream = Box::pin(stream);
                use futures_util::StreamExt;
                let mut buf = String::new();
                while let Some(chunk) = stream.next().await {
                    if *self.abort.lock().unwrap() {
                        break;
                    }
                    let Ok(bytes) = chunk else { break };
                    buf.push_str(&String::from_utf8_lossy(&bytes));
                    while let Some(pos) = buf.find("\n\n") {
                        let raw = buf[..pos].to_string();
                        buf = buf[pos + 2..].to_string();
                        for line in raw.lines() {
                            if let Some(data) = line.strip_prefix("data: ") {
                                if data.trim() == "[DONE]" {
                                    continue;
                                }
                                if let Ok(v) = serde_json::from_str::<Value>(data) {
                                    if let Some(delta) = v
                                        .pointer("/choices/0/delta/content")
                                        .and_then(|d| d.as_str())
                                    {
                                        full.push_str(delta);
                                        let _ = tx.send(ev(
                                            "message.part.updated",
                                            json!({
                                                "sessionID": session_id,
                                                "part": {"id": part_id, "messageID": assistant_id, "type": "text", "text": full}
                                            }),
                                        ));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Ok(res) => {
                let status = res.status();
                let text = res.text().await.unwrap_or_default();
                full = format!("⚠️ 模型请求失败 HTTP {status}: {text}");
            }
            Err(e) => {
                full = format!("⚠️ 模型请求失败: {e}");
            }
        }

        let full_len = full.chars().count();
        {
            let mut sessions = self.sessions.lock().unwrap();
            if let Some(s) = sessions.get_mut(session_id) {
                s.messages.push(MiniMsg {
                    id: assistant_id,
                    role: "assistant".into(),
                    text: full,
                    created: now(),
                });
                s.updated = now();
            }
        }
        *self.streaming.lock().unwrap() = None;
        *self.abort.lock().unwrap() = false;
        eprintln!(
            "[mini] 会话 {session_id} 对话结束 ({full_len} 字, {}ms)",
            t0.elapsed().as_millis()
        );
        let _ = tx.send(status("idle"));
        let _ = tx.send(ev("session.idle", json!({"sessionID": session_id})));
        let _ = prompt;
    }
}
