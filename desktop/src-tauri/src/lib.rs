mod agent;
mod engine;
mod relay;
mod store;

use crate::store::{Settings, Store};
use serde_json::json;
use std::sync::Arc;
use tokio::sync::Mutex;
use tauri::{AppHandle, Manager, State};

struct AppState {
    store: Arc<Store>,
    agent: Arc<Mutex<agent::OpenCodeAgent>>,
}

fn app_config_path(app: &AppHandle) -> std::path::PathBuf {
    let dir = app
        .path()
        .app_config_dir()
        .unwrap_or_else(|_| std::path::PathBuf::from("."));
    let _ = std::fs::create_dir_all(&dir);
    dir.join("config.json")
}

// ---------- 设置 ----------

#[tauri::command]
fn settings_get(state: State<AppState>) -> Result<serde_json::Value, String> {
    Ok(serde_json::to_value(state.store.get()).map_err(|e| e.to_string())?)
}

#[tauri::command]
fn settings_save(settings: Settings, state: State<AppState>) -> Result<(), String> {
    state.store.set(settings);
    Ok(())
}

// ---------- 账号 ----------

#[tauri::command]
async fn account_login(
    relay_url: String,
    email: String,
    password: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    let base = relay_url.trim_end_matches('/').to_string();
    let resp = relay::login(&base, &email, &password).await?;
    state.store.update(|cfg| {
        cfg.relay_url = base.clone();
        cfg.email = email.clone();
        cfg.token = resp.token.clone();
    });
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(resp.user)
}

#[tauri::command]
async fn account_register(
    relay_url: String,
    email: String,
    password: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    let base = relay_url.trim_end_matches('/').to_string();
    let resp = relay::register(&base, &email, &password).await?;
    state.store.update(|cfg| {
        cfg.relay_url = base.clone();
        cfg.email = email.clone();
        cfg.token = resp.token.clone();
    });
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(resp.user)
}

// ---------- 设备 ----------

#[tauri::command]
async fn device_register(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    let s = state.store.get();
    if s.token.is_empty() {
        return Err("请先登录".into());
    }
    let hostname = std::env::var("HOSTNAME")
        .or_else(|_| hostname())
        .unwrap_or_else(|_| "Mac".into());
    let resp =
        relay::register_device(&s.http_base(), &s.token, &format!("{hostname} ({})", s.email)).await?;
    state.store.update(|cfg| {
        cfg.device_id.clear();
        cfg.device_token.clear();
        cfg.pending_id = resp.pending_id.clone();
        cfg.pending_token = resp.pending_token.clone();
    });
    engine::log_event(&app, format!("📱 待配对设备已创建，配对码 {:.6}（{:.6} 秒有效）",
        resp.pairing_code, resp.expires_in));
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(json!({
        "pairingCode": resp.pairing_code,
        "expiresIn": resp.expires_in,
    }))
}

fn hostname() -> Result<String, std::io::Error> {
    use std::process::Command;
    let out = Command::new("hostname").output()?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[tauri::command]
async fn device_unbind(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.store.update(|cfg| {
        cfg.device_id.clear();
        cfg.device_token.clear();
        cfg.pending_id.clear();
        cfg.pending_token.clear();
    });
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(())
}

// ---------- Agent ----------

#[tauri::command]
async fn agent_detect(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let mut a = state.agent.lock().await;
    Ok(json!({
        "path": agent::detect(),
        "running": a.running(),
        "port": a.port,
    }))
}

#[tauri::command]
async fn agent_start(
    dir: String,
    permission: Option<String>,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    let mut a = state.agent.lock().await;
    a.start(&dir, permission.as_deref()).await?;
    state.store.update(|cfg| {
        cfg.agent_dir = dir;
        if let Some(p) = permission {
            cfg.permission = Some(p);
        }
    });
    let version = a.version().await;
    engine::log_event(&app, format!("🤖 Agent 已启动 (opencode {})", version.as_deref().unwrap_or("?")));
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(json!({"version": version}))
}

#[tauri::command]
async fn agent_stop(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let mut a = state.agent.lock().await;
    a.stop().await;
    engine::log_event(&app, "🛑 Agent 已停止");
    engine::emit_status(&app, &state.store, &state.agent, false).await;
    Ok(())
}

// ---------- 状态 ----------

#[tauri::command]
async fn engine_status(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let s = state.store.get();
    let mut a = state.agent.lock().await;
    Ok(json!({
        "paired": s.paired(),
        "pending": !s.pending_token.is_empty(),
        "loggedIn": !s.token.is_empty(),
        "agentRunning": a.running(),
        "agentPath": agent::detect(),
    }))
}

// ---------- 启动 ----------

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let handle = app.handle().clone();
            let path = app_config_path(&handle);
            let store = Arc::new(Store::load(path));
            let port = store.get().agent_port;
            let agent = Arc::new(Mutex::new(agent::OpenCodeAgent::new(
                if port == 0 { 4097 } else { port },
            )));
            app.manage(AppState {
                store: Arc::clone(&store),
                agent: Arc::clone(&agent),
            });
            // 后台引擎
            let app2 = handle.clone();
            let store2 = Arc::clone(&store);
            let agent2 = Arc::clone(&agent);
            tauri::async_runtime::spawn(async move {
                engine::run(app2, store2, agent2).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            settings_get,
            settings_save,
            account_login,
            account_register,
            device_register,
            device_unbind,
            agent_detect,
            agent_start,
            agent_stop,
            engine_status,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
