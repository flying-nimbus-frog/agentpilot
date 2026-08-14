mod agent;
mod agent_llm;
mod engine;
mod relay;
mod store;


use crate::store::{Settings, Store};
use serde_json::json;
use std::sync::Arc;
use tauri::{AppHandle, Manager, State};

struct AppState {
    store: Arc<Store>,
    mini: Arc<agent_llm::MiniAgent>,
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
    engine::emit_status(&app, &state.store, &state.mini, false).await;
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
    engine::emit_status(&app, &state.store, &state.mini, false).await;
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
    let hostname = machine_name();
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
    engine::emit_status(&app, &state.store, &state.mini, false).await;
    Ok(json!({
        "pairingCode": resp.pairing_code,
        "expiresIn": resp.expires_in,
    }))
}

/// 取 macOS 计算机名（如 "小彭的 MacBook Air"）；失败时兜底用 hostname 命令
fn machine_name() -> String {
    use std::process::Command;
    if let Ok(out) = Command::new("scutil")
        .args(["--get", "ComputerName"])
        .output()
    {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !name.is_empty() && !name.contains('.') {
            return name;
        }
    }
    if let Ok(out) = Command::new("hostname").output() {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !name.is_empty() && name != "localhost" && !name.contains('.') {
            return name;
        }
    }
    "Mac".into()
}

#[tauri::command]
async fn device_unbind(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.store.update(|cfg| {
        cfg.device_id.clear();
        cfg.device_token.clear();
        cfg.pending_id.clear();
        cfg.pending_token.clear();
    });
    engine::emit_status(&app, &state.store, &state.mini, false).await;
    Ok(())
}

// ---------- Agent（内置 MiniAgent，直连模型） ----------

#[tauri::command]
async fn agent_detect(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    Ok(json!({
        "type": "mini-agent",
        "model": state.mini.model_name(),
        "configured": state.mini.configured(),
    }))
}

#[tauri::command]
async fn agent_start(
    api_base: String,
    api_key: String,
    model: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    state.mini.configure(&api_base, &api_key, &model);
    state.store.update(|cfg| {
        cfg.api_base = api_base;
        cfg.api_key = api_key;
        cfg.model = model;
    });
    if !state.mini.configured() {
        return Err("请先填写 API Key".into());
    }
    engine::log_event(
        &app,
        format!("🤖 MiniAgent 已就绪 (model: {})", state.mini.model_name()),
    );
    engine::emit_status(&app, &state.store, &state.mini, false).await;
    Ok(json!({"model": state.mini.model_name()}))
}

#[tauri::command]
async fn agent_stop(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.mini.configure("", "", "");
    state.store.update(|cfg| {
        cfg.api_key.clear();
    });
    engine::log_event(&app, "🛑 MiniAgent 已停止");
    engine::emit_status(&app, &state.store, &state.mini, false).await;
    Ok(())
}

// ---------- 状态 ----------

#[tauri::command]
async fn engine_status(state: State<'_, AppState>) -> Result<serde_json::Value, String> {
    let s = state.store.get();
    Ok(json!({
        "paired": s.paired(),
        "pending": !s.pending_token.is_empty(),
        "loggedIn": !s.token.is_empty(),
        "agentRunning": state.mini.configured(),
        "agentModel": state.mini.model_name(),
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
            let mini = agent_llm::MiniAgent::new();
            // 恢复已保存的模型配置
            let s0 = store.get();
            mini.configure(&s0.api_base, &s0.api_key, &s0.model);
            app.manage(AppState {
                store: Arc::clone(&store),
                mini: Arc::clone(&mini),
            });
            // 后台引擎
            let app2 = handle.clone();
            let store2 = Arc::clone(&store);
            tauri::async_runtime::spawn(async move {
                engine::run(app2, store2, mini).await;
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
