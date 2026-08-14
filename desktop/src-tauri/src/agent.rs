/// opencode Agent 驱动：进程管理 + HTTP 客户端 + SSE 事件流。
use base64::Engine;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

const DEFAULT_PORT: u16 = 4097;

pub fn find_opencode() -> Option<PathBuf> {
    let candidates = [
        std::env::var("OPENCODE_BIN").ok().map(PathBuf::from),
        which("opencode"),
        Some(PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".bun/bin/opencode")),
        Some(PathBuf::from("/opt/homebrew/bin/opencode")),
        Some(PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/bin/opencode")),
    ];
    candidates.into_iter().flatten().find(|p| p.exists())
}

fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var("PATH").unwrap_or_default();
    for dir in path.split(':') {
        let p = PathBuf::from(dir).join(name);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// 杀掉占用指定端口的进程（macOS lsof；用于清理上次实例的孤儿 opencode）
async fn kill_port_occupant(port: u16) {
    let out = Command::new("lsof")
        .args(["-ti", &format!("tcp:{port}")])
        .output()
        .await;
    if let Ok(out) = out {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for pid in stdout.split_whitespace() {
            let _ = Command::new("kill").arg(pid).status().await;
        }
    }
}

pub struct OpenCodeAgent {
    pub port: u16,
    pub child: Option<Child>,
    password: String,
}

fn auth_header(password: &str) -> String {
    let cred = base64::engine::general_purpose::STANDARD.encode(format!("opencode:{password}"));
    format!("Basic {cred}")
}

impl OpenCodeAgent {
    pub fn new(port: u16) -> Self {
        OpenCodeAgent {
            port,
            child: None,
            password: format!("oc-remote-{}", std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)),
        }
    }

    pub fn password(&self) -> &str {
        &self.password
    }

    /// SSE 事件流 → 转发通道（静态方法，不持锁）
    pub async fn stream_events(port: u16, password: String, tx: mpsc::UnboundedSender<Value>) {
        let client = reqwest::Client::new();
        let url = format!("http://127.0.0.1:{port}/event");
        let res = match client
            .get(&url)
            .header("Authorization", auth_header(&password))
            .send()
            .await
        {
            Ok(r) => r,
            Err(_) => return,
        };
        let stream = res.bytes_stream();
        let mut stream = Box::pin(stream);
        use futures_util::StreamExt;
        let mut buf = String::new();
        while let Some(chunk) = stream.next().await {
            let Ok(bytes) = chunk else { break };
            buf.push_str(&String::from_utf8_lossy(&bytes));
            while let Some(pos) = buf.find("\n\n") {
                let raw = buf[..pos].to_string();
                buf = buf[pos + 2..].to_string();
                for line in raw.lines() {
                    if let Some(data) = line.strip_prefix("data: ") {
                        if let Ok(ev) = serde_json::from_str::<Value>(data) {
                            let _ = tx.send(json!({"type": "event", "event": ev}));
                        }
                    }
                }
            }
        }
    }

    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub async fn start(&mut self, dir: &str, permission: Option<&str>) -> Result<(), String> {
        let bin = find_opencode().ok_or("未找到 opencode，请先安装（bun install -g opencode-ai）")?;
        if let Some(child) = &mut self.child {
            if child.try_wait().ok().flatten().is_none() {
                return Ok(()); // 已在运行
            }
        }
        // 清理占用目标端口的进程（可能是上一次实例留下的孤儿 opencode）
        kill_port_occupant(self.port).await;
        let mut cmd = Command::new(&bin);
        cmd.args(["serve", "--hostname", "127.0.0.1", "--port", &self.port.to_string()])
            .current_dir(dir)
            .env("OPENCODE_SERVER_PASSWORD", &self.password)
            .env("OPENCODE_CLIENT", "opencode-remote-desktop")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(p) = permission.filter(|p| !p.trim().is_empty()) {
            cmd.env("OPENCODE_PERMISSION", p);
        }
        self.child = Some(cmd.spawn().map_err(|e| format!("启动失败: {e}"))?);
        // 等待就绪；进程提前退出则立即报错
        for _ in 0..30 {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            if let Some(child) = &mut self.child {
                if let Some(status) = child.try_wait().ok().flatten() {
                    return Err(format!("opencode 进程异常退出: {status}"));
                }
            }
            if self.health().await {
                return Ok(());
            }
        }
        Err("opencode 30 秒内未就绪".into())
    }

    pub async fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
    }

    pub fn running(&mut self) -> bool {
        if let Some(child) = &mut self.child {
            child.try_wait().ok().flatten().is_none()
        } else {
            false
        }
    }

    pub async fn health(&self) -> bool {
        self.request("GET", "/global/health", None)
            .await
            .map(|r| r.get("ok").and_then(|o| o.as_bool()).unwrap_or(false))
            .unwrap_or(false)
    }

    pub async fn version(&self) -> Option<String> {
        let resp = self.request("GET", "/global/health", None).await.ok()?;
        let data = resp.get("data")?;
        data.get("version")?.as_str().map(|s| s.to_string())
    }

    /// 执行 opencode REST 指令（代理手机端 cmd）
    pub async fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let client = reqwest::Client::new();
        let url = format!("{}{}", self.base(), path);
        let mut req = client
            .request(reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).unwrap_or(reqwest::Method::GET), &url)
            .header("Authorization", auth_header(&self.password))
            .header("Content-Type", "application/json");
        if let Some(b) = body {
            req = req.json(&b);
        }
        let res = req
            .send()
            .await
            .map_err(|e| format!("本地 opencode 请求失败: {e}"))?;
        let status = res.status();
        if status == 204 {
            return Ok(json!({"ok": true, "data": null}));
        }
        let data: Value = res.json().await.unwrap_or(Value::Null);
        if status.is_success() {
            Ok(json!({"ok": true, "data": data}))
        } else {
            Ok(json!({"ok": false, "error": format!("HTTP {status} {path}")}))
        }
    }
}

/// 检测 opencode 是否安装，返回路径
pub fn detect() -> Option<String> {
    find_opencode().map(|p| p.display().to_string())
}
