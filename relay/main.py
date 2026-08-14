import asyncio
import json
import logging
import os
import secrets
import time

import db
from auth import create_token, decode_token, hash_password, verify_password
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from hub import hub
from pydantic import BaseModel
from ratelimit import RateLimiter

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("relay")

app = FastAPI(title="OpenCode Remote Relay", version="2.1.0")

# 开发/Web 调试用 CORS（RELAY_CORS=1 开启；手机原生 App 不受 CORS 限制）
if os.environ.get("RELAY_CORS") == "1":
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

HEARTBEAT_TIMEOUT = 90  # 秒，超过视为离线
PAIRING_TTL_SEC = 600   # 配对码有效期
PAIRING_MAX_TRIES = 3   # 配对码最多尝试次数

# 限流（按 IP）
rl_register = RateLimiter(limit=5, window_sec=3600)      # 注册：5次/小时
rl_login = RateLimiter(limit=10, window_sec=60)          # 登录：10次/分钟
rl_pair = RateLimiter(limit=5, window_sec=60)            # 配对：5次/分钟
rl_global = RateLimiter(limit=600, window_sec=60)        # 全局兜底：600次/分钟

db.init_db()


# ---------- Pydantic 模型 ----------

class RegisterIn(BaseModel):
    email: str
    password: str


class LoginIn(BaseModel):
    email: str
    password: str


class DeviceIn(BaseModel):
    name: str


class PairIn(BaseModel):
    code: str


# ---------- REST ----------

def _client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _check_ratelimit(request: Request, limiter: RateLimiter, what: str):
    ip = _client_ip(request)
    if not rl_global.allow(ip):
        raise HTTPException(429, "请求过于频繁，请稍后再试")
    if not limiter.allow(ip):
        raise HTTPException(429, f"{what}过于频繁，请稍后再试")


@app.get("/health")
def health():
    return {"healthy": True, "service": "opencode-remote-relay", "version": "2.1.0"}


@app.post("/api/register")
def register(body: RegisterIn, request: Request):
    _check_ratelimit(request, rl_register, "注册")
    email = body.email.strip().lower()
    if not email or len(body.password) < 6:
        raise HTTPException(400, "邮箱或密码不合法（密码至少 6 位）")
    pwd_hash, salt = hash_password(body.password)
    user = db.create_user(email, pwd_hash, salt)
    if user is None:
        raise HTTPException(409, "邮箱已注册")
    return {"token": create_token(user["id"]), "user": user}


@app.post("/api/login")
def login(body: LoginIn, request: Request):
    _check_ratelimit(request, rl_login, "登录")
    email = body.email.strip().lower()
    user = db.get_user_by_email(email)
    if not user or not verify_password(body.password, user["salt"], user["password_hash"]):
        raise HTTPException(401, "邮箱或密码错误")
    rl_login.reset(_client_ip(request))
    return {"token": create_token(user["id"]), "user": {"id": user["id"], "email": user["email"]}}


def _require_user(authorization: str | None) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "未登录")
    user_id = decode_token(authorization[7:])
    if not user_id:
        raise HTTPException(401, "登录已过期")
    user = db.get_user(user_id)
    if not user:
        raise HTTPException(401, "用户不存在")
    return user


@app.get("/api/devices")
async def api_devices_list(authorization: str | None = Header(None)):
    user = _require_user(authorization)
    return {"devices": await hub.device_list_for_phone(user["id"])}


@app.post("/api/devices")
def api_devices_register(body: DeviceIn, authorization: str | None = Header(None)):
    """电脑端登录后申请设备绑定：返回配对码，手机确认后生效。"""
    user = _require_user(authorization)
    code = f"{secrets.randbelow(10)}{secrets.randbelow(10)}{secrets.randbelow(10)}{secrets.randbelow(10)}{secrets.randbelow(10)}{secrets.randbelow(10)}"
    dev = db.create_pending_device(user["id"], body.name, code, PAIRING_TTL_SEC)
    return {
        "pendingID": dev["id"],
        "pendingToken": dev["pendingToken"],
        "pairingCode": dev["pairingCode"],
        "expiresIn": PAIRING_TTL_SEC,
    }


@app.get("/api/devices/{device_id}/status")
def api_devices_status(device_id: str, token: str):
    """电脑端轮询配对状态（用 pendingToken）。激活后返回正式 deviceToken。"""
    dev = db.get_pending_device_by_token(token)
    if not dev or dev["id"] != device_id:
        raise HTTPException(404, "配对请求不存在或已失效")
    now = int(time.time() * 1000)
    if dev["status"] == "pending":
        if now > dev["pairing_expires"]:
            db.delete_device(dev["user_id"], device_id)
            raise HTTPException(410, "配对码已过期，请重新登录注册设备")
        return {"status": "pending"}
    # 已激活：返回正式令牌（pendingToken 校验通过后返回一次）
    return {"status": "active", "deviceToken": dev["token"]}


@app.post("/api/devices/{device_id}/pair")
def api_devices_pair(
    body: PairIn, device_id: str, authorization: str | None = Header(None),
    request: Request = None,
):
    """手机端确认配对：输入桌面端显示的 6 位配对码。"""
    _check_ratelimit(request, rl_pair, "配对")
    user = _require_user(authorization)
    dev = db.get_pending_device(device_id, user["id"])
    if not dev:
        raise HTTPException(404, "待配对设备不存在")
    now = int(time.time() * 1000)
    if now > dev["pairing_expires"]:
        db.delete_device(user["id"], device_id)
        raise HTTPException(410, "配对码已过期，请电脑端重新注册")
    if body.code != dev["pairing_code"]:
        raise HTTPException(401, "配对码错误")
    result = db.activate_pending_device(device_id, user["id"])
    if not result:
        raise HTTPException(409, "设备状态异常")
    log.info("device paired: %s (%s)", device_id, dev["name"])
    return result


@app.delete("/api/devices/{device_id}")
async def api_devices_delete(device_id: str, authorization: str | None = Header(None)):
    user = _require_user(authorization)
    if hub.is_device_online(device_id):
        raise HTTPException(400, "设备在线，请先断开")
    if not db.delete_device(user["id"], device_id):
        raise HTTPException(404, "设备不存在")
    return {"ok": True}


# ---------- WebSocket 助手 ----------

async def ws_recv(ws: WebSocket):
    """带心跳超时的收消息。"""
    try:
        return await asyncio.wait_for(ws.receive_text(), timeout=HEARTBEAT_TIMEOUT)
    except asyncio.TimeoutError:
        return None


def _send(ws: WebSocket, msg: dict):
    return ws.send_text(json.dumps(msg))


# ---------- 手机端 WS ----------

@app.websocket("/ws/phone")
async def ws_phone(ws: WebSocket):
    token = ws.query_params.get("token", "")
    user_id = decode_token(token)
    if not user_id:
        await ws.close(code=4401)
        return
    await ws.accept()
    await hub.phone_connect(user_id, ws)
    log.info("phone connected: user=%s", user_id)
    try:
        await _send(ws, {"type": "device.list", "devices": await hub.device_list_for_phone(user_id)})
        while True:
            raw = await ws_recv(ws)
            if raw is None:
                break
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            t = msg.get("type")
            if t == "ping":
                await _send(ws, {"type": "pong"})
            elif t == "cmd":
                device_id = msg.get("deviceID")
                req_id = msg.get("id")
                cmd = msg.get("cmd")
                if not device_id or not req_id or not cmd:
                    continue
                if not hub.is_device_online(device_id):
                    await _send(
                        ws,
                        {"type": "cmd.result", "id": req_id, "ok": False, "error": "设备离线"},
                    )
                    continue
                fwd = {"type": "cmd", "id": req_id, "cmd": cmd}
                if not await hub.send_to_device(device_id, fwd):
                    await _send(
                        ws,
                        {"type": "cmd.result", "id": req_id, "ok": False, "error": "设备离线"},
                    )
    except WebSocketDisconnect:
        pass
    finally:
        await hub.phone_disconnect(user_id, ws)
        log.info("phone disconnected: user=%s", user_id)


# ---------- 电脑端 WS ----------

@app.websocket("/ws/device")
async def ws_device(ws: WebSocket):
    token = ws.query_params.get("token", "")
    device = db.get_device_by_token(token)
    if not device:
        await ws.close(code=4401)
        return
    await ws.accept()
    db.touch_device(device["id"])
    await hub.device_connect(device["id"], device["user_id"], device["name"], ws)
    log.info("device online: %s (%s)", device["id"], device["name"])
    try:
        while True:
            raw = await ws_recv(ws)
            if raw is None:
                break
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            t = msg.get("type")
            if t == "ping":
                await _send(ws, {"type": "pong"})
            elif t == "cmd.result":
                await hub.broadcast(device["user_id"], msg)
            elif t == "event":
                await hub.broadcast(
                    device["user_id"],
                    {"type": "event", "event": msg.get("event")},
                )
    except WebSocketDisconnect:
        pass
    finally:
        await hub.device_disconnect(device["id"])
        log.info("device offline: %s", device["id"])


if __name__ == "__main__":
    import os

    import uvicorn

    db.init_db()
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("RELAY_PORT", "8000")))
