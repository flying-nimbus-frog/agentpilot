#!/usr/bin/env python3
"""OpenCode Remote 电脑端伴侣守护进程。

用法:
  python main.py --login --relay ws://服务器:8000 --email 你的邮箱 --password 密码
  python main.py --run [--relay ws://服务器:8000] [--dir 项目目录]

流程:
  --login   向中继注册本机设备，保存设备令牌
  --run     拉起本地 opencode serve → 连接中继 → 代理指令 + 转发事件
"""
import argparse
import asyncio
import json
import os
import random
import secrets
import shutil
import signal
import sys
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed

sys.path.insert(0, str(Path(__file__).parent))

import config as cfg
from opencode_client import OpenCodeClient

HTTP_TIMEOUT = 300  # 长指令（如 prompt_async 之外的同步指令）超时


def log(msg: str):
    print(f"[companion] {msg}", flush=True)


def find_opencode() -> str:
    exe = shutil.which("opencode")
    if exe:
        return exe
    candidates = [
        Path.home() / ".bun/bin/opencode",
        Path.home() / ".local/bin/opencode",
        Path("/opt/homebrew/bin/opencode"),
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    return "opencode"


# ---------- 本地 opencode 管理 ----------

class OpenCodeProc:
    def __init__(self, port: int, password: str, directory: str, permission: dict | None = None):
        self.port = port
        self.password = password
        self.directory = directory
        self.permission = permission
        self.proc: asyncio.subprocess.Process | None = None

    async def start(self):
        env = dict(os.environ)
        env["OPENCODE_SERVER_PASSWORD"] = self.password
        env["OPENCODE_CLIENT"] = "opencode-remote-companion"
        if self.permission is not None:
            env["OPENCODE_PERMISSION"] = json.dumps(self.permission)
        cmd = [
            find_opencode(),
            "serve",
            "--hostname", "127.0.0.1",
            "--port", str(self.port),
        ]
        log("启动本地 opencode: " + " ".join(cmd))
        self.proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=self.directory,
            env=env,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        client = OpenCodeClient("127.0.0.1", self.port, self.password)
        for _ in range(30):
            await asyncio.sleep(1)
            h = await client.health()
            if h.get("ok"):
                await client.aclose()
                return h["data"].get("version")
        await client.aclose()
        raise RuntimeError("本地 opencode serve 30 秒内未就绪")

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.terminate()
            try:
                await asyncio.wait_for(self.proc.wait(), 5)
            except asyncio.TimeoutError:
                self.proc.kill()


# ---------- 中继连接 ----------

async def relay_loop(conf: cfg.Config, client: OpenCodeClient):
    """连接中继并处理消息；断线自动重连。"""
    url = conf.relay_url.rstrip("/") + f"/ws/device?token={conf.device_token}"
    backoff = 1
    while True:
        try:
            async with websockets.connect(url, ping_interval=20, ping_timeout=40) as ws:
                backoff = 1
                log(f"已连接中继: {conf.relay_url}")
                # 事件转发任务
                event_task = asyncio.create_task(forward_events(ws, client))
                try:
                    async for raw in ws:
                        try:
                            msg = json.loads(raw)
                        except json.JSONDecodeError:
                            continue
                        t = msg.get("type")
                        if t == "ping":
                            await ws.send(json.dumps({"type": "pong"}))
                        elif t == "cmd":
                            asyncio.create_task(handle_cmd(ws, client, msg))
                finally:
                    event_task.cancel()
                    try:
                        await event_task
                    except asyncio.CancelledError:
                        pass
        except (ConnectionClosed, OSError) as e:
            log(f"中继连接断开({e})，{backoff}s 后重连…")
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, 60)


async def handle_cmd(ws, client: OpenCodeClient, msg: dict):
    cmd = msg.get("cmd") or {}
    req_id = msg.get("id")
    log(f"收到指令 {req_id}: {cmd.get('method')} {cmd.get('path')}")
    result = await client.request(
        cmd.get("method", "GET"), cmd.get("path", "/"), cmd.get("body")
    )
    reply = {"type": "cmd.result", "id": req_id, **result}
    try:
        await ws.send(json.dumps(reply))
    except ConnectionClosed:
        pass


async def forward_events(ws, client: OpenCodeClient):
    async for event in client.events():
        try:
            await ws.send(json.dumps({"type": "event", "event": event}))
        except ConnectionClosed:
            return


# ---------- 注册设备 ----------

def http_post_json(url: str, path: str, payload: dict, token: str | None = None) -> dict:
    import urllib.request

    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url.rstrip("/") + path, data=json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            return {"ok": True, "data": json.loads(r.read())}
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read()).get("detail", str(e))
        except Exception:
            detail = str(e)
        return {"ok": False, "error": detail}


def cmd_login(args) -> int:
    http = args.relay.replace("ws://", "http://").replace("wss://", "https://")
    res = http_post_json(http, "/api/login", {"email": args.email, "password": args.password})
    if not res["ok"]:
        print(f"[companion] 登录失败: {res['error']}")
        return 1
    token = res["data"]["token"]
    hostname = os.uname().nodename if hasattr(os, "uname") else "Mac"
    res2 = http_post_json(
        http, "/api/devices", {"name": f"{hostname} ({args.email})"}, token=token
    )
    if not res2["ok"]:
        print(f"[companion] 设备注册失败: {res2['error']}")
        return 1
    conf = cfg.Config({})
    conf.relay_url = args.relay
    conf.device_id = res2["data"]["deviceID"]
    conf.device_token = res2["data"]["deviceToken"]
    conf.opencode_password = f"oc-{secrets.token_urlsafe(16)}"
    conf.directory = str(Path(args.dir or os.getcwd()).resolve())
    cfg.save(conf)
    print(f"[companion] ✅ 设备已注册: {conf.device_id}")
    print(f"[companion] 配置已保存: {cfg.CONFIG_FILE}")
    return 0


def cmd_run(args) -> int:
    conf = cfg.load()
    if conf is None:
        print("[companion] 尚未登录，先执行: python main.py --login --email 你的邮箱 --password 密码")
        return 1
    if args.relay:
        conf.relay_url = args.relay
    if args.dir:
        conf.directory = str(Path(args.dir).resolve())

    proc = OpenCodeProc(
        conf.opencode_port, conf.opencode_password, conf.directory, conf.permission
    )
    client = OpenCodeClient("127.0.0.1", conf.opencode_port, conf.opencode_password)

    async def amain() -> int:
        try:
            version = await proc.start()
            log(f"本地 opencode v{version} 就绪 @ :{conf.opencode_port}")
            await relay_loop(conf, client)
        finally:
            await proc.stop()
            await client.aclose()
        return 0

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    stop = asyncio.Event()
    loop.add_signal_handler(signal.SIGINT, stop.set)
    try:
        return loop.run_until_complete(_run_with_stop(amain(), stop))
    finally:
        loop.close()


async def _run_with_stop(coro, stop: asyncio.Event):
    task = asyncio.create_task(coro)
    await stop.wait()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    return 0


def main():
    parser = argparse.ArgumentParser(description="OpenCode Remote 电脑端伴侣")
    subparsers = parser.add_subparsers(dest="command", required=True)
    sub = subparsers

    p_login = sub.add_parser("login", help="登录并注册本机设备")
    p_login.add_argument("--relay", required=True, help="中继地址，如 ws://server:8000")
    p_login.add_argument("--email", required=True)
    p_login.add_argument("--password", required=True)
    p_login.add_argument("--dir", help="默认工作目录")

    p_run = sub.add_parser("run", help="运行守护进程")
    p_run.add_argument("--relay", help="覆盖中继地址")
    p_run.add_argument("--dir", help="覆盖工作目录")

    args = parser.parse_args()
    if args.command == "login":
        sys.exit(cmd_login(args))
    sys.exit(cmd_run(args))


if __name__ == "__main__":
    main()
