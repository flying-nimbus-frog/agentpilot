use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Debug, Deserialize)]
pub struct LoginResp {
    pub token: String,
    pub user: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct RegisterDeviceResp {
    #[serde(rename = "pendingID")]
    pub pending_id: String,
    #[serde(rename = "pendingToken")]
    pub pending_token: String,
    #[serde(rename = "pairingCode")]
    pub pairing_code: String,
    #[serde(rename = "expiresIn")]
    pub expires_in: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairStatus {
    pub status: String,
    #[serde(default)]
    pub device_token: Option<String>,
}

pub async fn health(base: &str) -> Result<serde_json::Value, String> {
    let url = format!("{}/health", base);
    reqwest::get(&url)
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())
}

pub async fn login(base: &str, email: &str, password: &str) -> Result<LoginResp, String> {
    let url = format!("{}/api/login", base);
    let client = reqwest::Client::new();
    let res = client
        .post(&url)
        .json(&json!({"email": email, "password": password}))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = res.status();
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let msg = body.get("detail").and_then(|d| d.as_str()).unwrap_or("登录失败");
        return Err(msg.to_string());
    }
    serde_json::from_value(body).map_err(|e| e.to_string())
}

pub async fn register(base: &str, email: &str, password: &str) -> Result<LoginResp, String> {
    let url = format!("{}/api/register", base);
    let client = reqwest::Client::new();
    let res = client
        .post(&url)
        .json(&json!({"email": email, "password": password}))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = res.status();
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let msg = body
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("注册失败");
        return Err(msg.to_string());
    }
    serde_json::from_value(body).map_err(|e| e.to_string())
}

pub async fn register_device(base: &str, token: &str, name: &str) -> Result<RegisterDeviceResp, String> {
    let url = format!("{}/api/devices", base);
    let client = reqwest::Client::new();
    let res = client
        .post(&url)
        .bearer_auth(token)
        .json(&json!({"name": name}))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = res.status();
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let msg = body
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("设备注册失败");
        return Err(msg.to_string());
    }
    serde_json::from_value(body).map_err(|e| e.to_string())
}

pub async fn pair_status(base: &str, device_id: &str, pending_token: &str) -> Result<PairStatus, String> {
    let url = format!(
        "{}/api/devices/{}/status?token={}",
        base, device_id, pending_token
    );
    let client = reqwest::Client::new();
    let res = client.get(&url).send().await.map_err(|e| e.to_string())?;
    let status = res.status();
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    if status == 404 || status == 410 {
        let msg = body
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("配对请求失效");
        return Err(msg.to_string());
    }
    if !status.is_success() {
        return Err("查询配对状态失败".into());
    }
    serde_json::from_value(body).map_err(|e| e.to_string())
}

/// 设备 WS 通道消息（与 PROTOCOL.md 一致）
#[derive(Debug, Serialize, Deserialize)]
pub struct WsCmd {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub cmd: WsCmdInner,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct WsCmdInner {
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub body: Option<serde_json::Value>,
}
