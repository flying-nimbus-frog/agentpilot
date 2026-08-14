import json
import os
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "opencode-remote"
CONFIG_FILE = CONFIG_DIR / "companion.json"


class Config:
    def __init__(self, data: dict):
        self.relay_url: str = data.get("relay_url", "ws://localhost:8080")
        self.device_id: str = data.get("device_id", "")
        self.device_token: str = data.get("device_token", "")
        self.pending_id: str = data.get("pending_id", "")
        self.pending_token: str = data.get("pending_token", "")
        self.opencode_port: int = int(data.get("opencode_port", 4097))
        self.opencode_password: str = data.get("opencode_password", "")
        self.directory: str = data.get("directory", os.getcwd())
        self.permission: dict | None = data.get("permission")

    @property
    def paired(self) -> bool:
        return bool(self.device_token)

    def to_dict(self) -> dict:
        d = {
            "relay_url": self.relay_url,
            "device_id": self.device_id,
            "device_token": self.device_token,
            "pending_id": self.pending_id,
            "pending_token": self.pending_token,
            "opencode_port": self.opencode_port,
            "opencode_password": self.opencode_password,
            "directory": self.directory,
        }
        if self.permission is not None:
            d["permission"] = self.permission
        return d


def load() -> Config | None:
    if not CONFIG_FILE.exists():
        return None
    try:
        return Config(json.loads(CONFIG_FILE.read_text()))
    except Exception:
        return None


def save(cfg: Config) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg.to_dict(), indent=2, ensure_ascii=False))
    try:
        os.chmod(CONFIG_FILE, 0o600)
    except OSError:
        pass


def reset() -> None:
    if CONFIG_FILE.exists():
        CONFIG_FILE.unlink()
