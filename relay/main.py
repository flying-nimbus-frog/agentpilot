import asyncio
import json
import logging
import os
import secrets
import time

import db
import dotenv
import mailer
import apns
import pages
from auth import (
    create_one_time_token,
    create_token,
    decode_token,
    hash_password,
    verify_one_time_token,
    verify_password,
)
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from hub import hub
from pydantic import BaseModel
from ratelimit import RateLimiter

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("relay")

app = FastAPI(title="AgentPilot Relay", version="2.1.0")

# 开发/Web 调试用 CORS（RELAY_CORS=1 开启；手机原生 App 不受 CORS 限制）
if os.environ.get("RELAY_CORS") == "1":
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

dotenv.load_dotenv()

HEARTBEAT_TIMEOUT = 90  # 秒，超过视为离线
FREE_DEVICE_LIMIT = 1   # 免费套餐可绑定的设备数

PLAN_SECRET = os.environ.get("RELAY_PLAN_SECRET", "")
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


class ForgotIn(BaseModel):
    email: str


class PushTokenIn(BaseModel):
    token: str


class PlanGrantIn(BaseModel):
    secret: str
    email: str
    plan: str = "pro"
    months: int = 1


class ResetIn(BaseModel):
    token: str
    password: str


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
        raise HTTPException(429, "Too many requests, please try again later")
    if not limiter.allow(ip):
        raise HTTPException(429, f"{what} attempts too frequently, please try again later")


@app.get("/health")
def health():
    return {"healthy": True, "service": "opencode-remote-relay", "version": "2.1.0"}


@app.post("/api/register")
def register(body: RegisterIn, request: Request):
    _check_ratelimit(request, rl_register, "Registration")
    email = body.email.strip().lower()
    if not email or len(body.password) < 6:
        raise HTTPException(400, "Invalid email or password (password must be at least 6 characters)")
    pwd_hash, salt = hash_password(body.password)
    user = db.create_user(email, pwd_hash, salt)
    if user is None:
        raise HTTPException(409, "Email already registered")
    # 发送邮箱验证邮件（未配置 SMTP 时链接打印到日志）
    vt = create_one_time_token(user["id"], "verify", 24 * 3600)
    mailer.send_mail(
        email,
        "AgentPilot email verification",
        f"欢迎注册 AgentPilot！请点击以下链接完成邮箱验证（24 小时内有效）：\n\n{mailer.build_verify_url(vt)}",
    )
    ver = 0
    return {
        "token": create_token(user["id"], ver),
        "user": {**user, "emailVerified": False},
        "verificationSent": mailer.enabled(),
    }


@app.post("/api/login")
def login(body: LoginIn, request: Request):
    _check_ratelimit(request, rl_login, "Login")
    email = body.email.strip().lower()
    user = db.get_user_by_email(email)
    if not user or not verify_password(body.password, user["salt"], user["password_hash"]):
        raise HTTPException(401, "Incorrect email or password")
    rl_login.reset(_client_ip(request))
    return {
        "token": create_token(user["id"], user["session_version"]),
        "user": {
            "id": user["id"],
            "email": user["email"],
            "emailVerified": bool(user["email_verified"]),
            "plan": user["plan"],
            "planExpires": user["plan_expires"],
        },
    }


def _require_user(authorization: str | None) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not logged in")
    payload = decode_token(authorization[7:])
    if not payload or payload.get("purpose", "auth") != "auth":
        raise HTTPException(401, "Session expired")
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(401, "Session expired")
    user = db.get_user(user_id)
    if not user:
        raise HTTPException(401, "User not found")
    # 会话吊销检查：token 中的版本必须等于当前版本
    if payload.get("ver", 0) != user["session_version"]:
        raise HTTPException(401, "Session revoked, please log in again")
    return user


@app.post("/api/push/register")
def api_push_register(body: PushTokenIn, authorization: str | None = Header(None)):
    """手机端注册 APNs 推送 token（登录后调用）。"""
    user = _require_user(authorization)
    if not body.token:
        raise HTTPException(400, "token required")
    db.save_push_token(user["id"], body.token)
    return {"ok": True, "pushEnabled": apns.enabled()}


@app.delete("/api/push/register")
def api_push_unregister(body: PushTokenIn, authorization: str | None = Header(None)):
    """注销推送 token（退出登录时调用）。"""
    user = _require_user(authorization)
    db.remove_push_token(user["id"], body.token)
    return {"ok": True}


@app.get("/api/plan")
def api_plan(authorization: str | None = Header(None)):
    """查询当前套餐。"""
    user = _require_user(authorization)
    limit = FREE_DEVICE_LIMIT if user["plan"] != "pro" else -1
    return {
        "plan": user["plan"],
        "planExpires": user["plan_expires"],
        "deviceLimit": limit,
        "activeDevices": db.count_bound_devices(user["id"]),
    }


@app.post("/api/plan/grant")
def api_plan_grant(body: PlanGrantIn):
    """套餐授权回调（由支付平台/管理端调用）。

    对接流程：支付平台 webhook → 这里校验 RELAY_PLAN_SECRET → 更新用户套餐。
    body: { secret, email, plan, months }
    """
    if not PLAN_SECRET or body.secret != PLAN_SECRET:
        raise HTTPException(401, "Invalid secret")
    user = db.get_user_by_email(body.email.strip().lower())
    if not user:
        raise HTTPException(404, "User not found")
    db.set_plan(user["id"], body.plan, body.months)
    return {"ok": True, "plan": body.plan}


@app.get("/api/verify", response_class=HTMLResponse)
def api_verify(token: str, request: Request = None):
    """邮箱验证（邮件里的链接）。"""
    user_id = verify_one_time_token(token, "verify")
    if not user_id:
        if request and "text/html" in request.headers.get("accept", ""):
            return pages.verify_failed()
        raise HTTPException(400, "Verification link is invalid or has expired")
    db.mark_email_verified(user_id)
    if request and "text/html" in request.headers.get("accept", ""):
        return pages.verify_success()
    return {"ok": True, "message": "Email verified successfully"}


@app.post("/api/resend-verification")
def api_resend_verification(authorization: str | None = Header(None)):
    """重新发送邮箱验证邮件。"""
    user = _require_user(authorization)
    if user["email_verified"]:
        return {"ok": True, "message": "Email already verified"}
    vt = create_one_time_token(user["id"], "verify", 24 * 3600)
    mailer.send_mail(
        user["email"],
        "AgentPilot email verification",
        f"Welcome to AgentPilot! Click the link below to verify your email (valid for 24 hours):\n\n{mailer.build_verify_url(vt)}",
    )
    return {"ok": True, "message": "Verification email sent", "verificationSent": mailer.enabled()}


@app.post("/api/forgot-password")
def api_forgot_password(body: ForgotIn, request: Request):
    """发送密码重置邮件（无论邮箱是否存在都返回成功，防枚举）。"""
    _check_ratelimit(request, rl_register, "Password recovery")
    email = body.email.strip().lower()
    user = db.get_user_by_email(email)
    if user:
        rt = create_one_time_token(user["id"], "reset", 3600)
        mailer.send_mail(
            email,
            "AgentPilot password reset",
            f"Click the link below to reset your password (valid for 1 hour):\n\n{mailer.build_reset_url(rt)}",
        )
    return {"ok": True, "message": "If the email is registered, a reset link has been sent"}


@app.get("/api/reset-password", response_class=HTMLResponse)
def api_reset_password_page(token: str, request: Request = None):
    """邮件链接：渲染移动友好的重置密码表单。"""
    user_id = verify_one_time_token(token, "reset")
    if not user_id:
        return pages.reset_invalid()
    return pages.reset_form(token)


@app.post("/api/reset-password")
def api_reset_password(body: ResetIn, request: Request):
    """用邮件里的令牌重置密码。"""
    _check_ratelimit(request, rl_register, "Password reset")
    user_id = verify_one_time_token(body.token, "reset")
    if not user_id:
        raise HTTPException(400, "Reset link is invalid or has expired")
    if len(body.password) < 6:
        raise HTTPException(400, "Password must be at least 6 characters")
    pwd_hash, salt = hash_password(body.password)
    with db._conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash=?, salt=? WHERE id=?",
            (pwd_hash, salt, user_id),
        )
    db.bump_session_version(user_id)  # 重置后所有旧登录失效
    return {"ok": True, "message": "Password has been reset, please log in again"}


@app.post("/api/sessions/revoke")
def api_sessions_revoke(authorization: str | None = Header(None)):
    """登出所有设备：所有已签发的 JWT 立即失效。"""
    user = _require_user(authorization)
    db.bump_session_version(user["id"])
    return {"ok": True, "message": "All sessions have been revoked"}


@app.get("/api/devices")
async def api_devices_list(authorization: str | None = Header(None)):
    user = _require_user(authorization)
    return {"devices": await hub.device_list_for_phone(user["id"])}


@app.post("/api/devices")
def api_devices_register(body: DeviceIn, authorization: str | None = Header(None)):
    """电脑端登录后申请设备绑定：返回配对码，手机确认后生效。"""
    user = _require_user(authorization)
    # 免费套餐设备数限制
    plan = user["plan"]
    limit = FREE_DEVICE_LIMIT if plan != "pro" else 999
    if db.count_bound_devices(user["id"]) >= limit:
        raise HTTPException(403, "Free plan allows 1 device. Upgrade to Pro for unlimited devices.")
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
        raise HTTPException(404, "Pairing request not found")
    now = int(time.time() * 1000)
    if dev["status"] == "pending":
        if now > dev["pairing_expires"]:
            db.delete_device(dev["user_id"], device_id)
            raise HTTPException(410, "Pairing code expired, please re-register on the computer")
        return {"status": "pending"}
    # 已激活：返回正式令牌（pendingToken 校验通过后返回一次）
    return {"status": "active", "deviceToken": dev["token"]}


@app.post("/api/devices/pair")
def api_devices_pair_by_code(
    body: PairIn, authorization: str | None = Header(None), request: Request = None
):
    """手机端确认配对（按配对码匹配，无需指定设备ID）。"""
    _check_ratelimit(request, rl_pair, "Pairing")
    user = _require_user(authorization)
    code = body.code.strip()
    devs = db.list_pending_devices(user["id"])
    now = int(time.time() * 1000)
    for dev in devs:
        if dev["pairing_code"] == code:
            if now > dev["pairing_expires"]:
                db.delete_device(user["id"], dev["id"])
                raise HTTPException(410, "Pairing code expired, please re-register on the computer")
            # 免费套餐兜底：激活时再查一次额度
            plan = user["plan"]
            limit = FREE_DEVICE_LIMIT if plan != "pro" else 999
            if db.count_bound_devices(user["id"]) >= limit:
                raise HTTPException(403, "Free plan allows 1 device. Upgrade to Pro for unlimited devices.")
            result = db.activate_pending_device(dev["id"], user["id"])
            if not result:
                raise HTTPException(409, "Device state error")
            log.info("device paired by code: %s (%s)", dev["id"], dev["name"])
            return result
    raise HTTPException(401, "Incorrect pairing code")


@app.post("/api/devices/{device_id}/pair")
def api_devices_pair(
    body: PairIn, device_id: str, authorization: str | None = Header(None),
    request: Request = None,
):
    """手机端确认配对：输入桌面端显示的 6 位配对码。"""
    _check_ratelimit(request, rl_pair, "Pairing")
    user = _require_user(authorization)
    dev = db.get_pending_device(device_id, user["id"])
    if not dev:
        raise HTTPException(404, "Pending device not found")
    now = int(time.time() * 1000)
    if now > dev["pairing_expires"]:
        db.delete_device(user["id"], device_id)
        raise HTTPException(410, "Pairing code expired, please re-register on the computer")
    if body.code != dev["pairing_code"]:
        raise HTTPException(401, "Incorrect pairing code")
    result = db.activate_pending_device(device_id, user["id"])
    if not result:
        raise HTTPException(409, "Device state error")
    log.info("device paired: %s (%s)", device_id, dev["name"])
    return result


@app.delete("/api/devices/{device_id}")
async def api_devices_delete(device_id: str, authorization: str | None = Header(None)):
    user = _require_user(authorization)
    if hub.is_device_online(device_id):
        raise HTTPException(400, "Device is online, please disconnect it first")
    if not db.delete_device(user["id"], device_id):
        raise HTTPException(404, "Device not found")
    return {"ok": True}


async def _send_push(token: str, title: str, body: str) -> None:
    await asyncio.to_thread(apns.push, token, title, body)


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
    payload = decode_token(token)
    if not payload or payload.get("purpose", "auth") != "auth":
        await ws.close(code=4401)
        return
    user_id = payload.get("sub")
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
                        {"type": "cmd.result", "id": req_id, "ok": False, "error": "Device is offline"},
                    )
                    continue
                fwd = {"type": "cmd", "id": req_id, "cmd": cmd}
                if not await hub.send_to_device(device_id, fwd):
                    await _send(
                        ws,
                        {"type": "cmd.result", "id": req_id, "ok": False, "error": "Device is offline"},
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
                # 审批/补充信息 → APNs 推送（手机后台也能收到提醒）
                ev = msg.get("event") or {}
                if ev.get("type") in ("permission.asked", "permission.ask"):
                    props = ev.get("properties") or {}
                    tool = props.get("permission") or props.get("tool") or "unknown"
                    user_text = props.get("userText") or ""
                    title = "需要你的授权" if not user_text else "需要补充信息"
                    body = user_text if user_text else f"Agent 请求执行: {tool}"
                    for tkn in db.list_push_tokens(device["user_id"]):
                        asyncio.create_task(_send_push(tkn, title, body))
    except WebSocketDisconnect:
        pass
    finally:
        await hub.device_disconnect(device["id"], ws)
        log.info("device offline: %s", device["id"])


if __name__ == "__main__":
    import os

    import uvicorn

    db.init_db()
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("RELAY_PORT", "8000")))
