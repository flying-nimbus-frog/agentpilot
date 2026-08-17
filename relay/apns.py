"""APNs 推送（.p8 Auth Key, ES256 JWT）。
用法：配置环境变量 RELAY_APNS_KEY_PATH / KEY_ID / TEAM_ID / TOPIC 后调用 push()。
"""
import json
import logging
import os
import time
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from fastapi import HTTPException

log = logging.getLogger("relay.apns")

KEY_PATH = os.environ.get("RELAY_APNS_KEY_PATH", "")
KEY_ID = os.environ.get("RELAY_APNS_KEY_ID", "")
TEAM_ID = os.environ.get("RELAY_APNS_TEAM_ID", "")
TOPIC = os.environ.get("RELAY_APNS_TOPIC", "net.zhileai.agentpilot")
# 生产环境 api.push.apple.com；沙盒 api.sandbox.push.apple.com
APNS_URL = os.environ.get("RELAY_APNS_URL", "https://api.push.apple.com")


def enabled() -> bool:
    return bool(KEY_PATH and KEY_ID and TEAM_ID)


def _auth_token() -> str:
    if not enabled():
        raise HTTPException(503, "APNs 未配置")
    key_data = Path(KEY_PATH).read_bytes()
    private_key = serialization.load_pem_private_key(key_data, password=None)
    now = int(time.time())
    return jwt.encode(
        {"iss": TEAM_ID, "iat": now, "exp": now + 3600},
        private_key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def push(device_token: str, title: str, body: str) -> str:
    """发送一条 alert 推送。返回: "ok" / "bad_token" / "error"。"""
    if not enabled():
        log.warning("[apns] 未配置，跳过推送: %s", title)
        return "error"
    import httpx

    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
        }
    }
    try:
        with httpx.Client(http2=True, timeout=10) as client:
            res = client.post(
                f"{APNS_URL}/3/device/{device_token}",
                json=payload,
                headers={
                    "authorization": f"bearer {_auth_token()}",
                    "apns-topic": TOPIC,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                },
            )
        if res.status_code == 200:
            log.info("[apns] 推送成功: %s", title)
            return "ok"
        # BadDeviceToken(400) / Unregistered(410) = token 失效，调用方应清理
        if (res.status_code in (400, 410)) and (
            "BadDeviceToken" in res.text or "Unregistered" in res.text
        ):
            log.warning("[apns] token 失效: %s", res.text)
            return "bad_token"
        log.error("[apns] 推送失败 %s: %s", res.status_code, res.text)
        return "error"
    except Exception as e:
        log.error("[apns] 推送异常: %s", e)
        return "error"
