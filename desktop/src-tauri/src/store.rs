use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Settings {
    pub relay_url: String,
    pub email: String,
    pub token: String,
    pub device_id: String,
    pub device_token: String,
    pub pending_id: String,
    pub pending_token: String,
    #[serde(default)]
    pub agent_dir: String,
    #[serde(default)]
    pub agent_port: u16,
    #[serde(default)]
    pub permission: Option<String>,
    #[serde(default)]
    pub api_base: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default)]
    pub model: String,
}

impl Settings {
    pub fn http_base(&self) -> String {
        self.relay_url.trim_end_matches('/').to_string()
    }
    pub fn ws_base(&self) -> String {
        self.relay_url
            .replace("https://", "wss://")
            .replace("http://", "ws://")
    }
    pub fn paired(&self) -> bool {
        !self.device_token.is_empty()
    }
}

pub struct Store {
    path: PathBuf,
    inner: Mutex<Settings>,
}

impl Store {
    pub fn load(path: PathBuf) -> Self {
        let settings = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str::<Settings>(&s).ok())
            .unwrap_or_default();
        Store {
            path,
            inner: Mutex::new(settings),
        }
    }

    pub fn get(&self) -> Settings {
        self.inner.lock().unwrap().clone()
    }

    pub fn set(&self, s: Settings) {
        *self.inner.lock().unwrap() = s.clone();
        let _ = std::fs::write(&self.path, serde_json::to_string_pretty(&s).unwrap());
    }

    pub fn update<F: FnOnce(&mut Settings)>(&self, f: F) {
        let mut s = self.inner.lock().unwrap();
        f(&mut s);
        let _ = std::fs::write(&self.path, serde_json::to_string_pretty(&*s).unwrap());
    }
}
