"""手机端全链路模拟：登录 → 设备列表 → 会话 → 发消息 → 流式事件 → 权限审批。

用法: python test_phone.py <relay_ws_url> <email> <password>
"""
import asyncio
import json
import sys
import urllib.request

import websockets


def http_json(url: str, payload: dict, token: str | None = None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


async def main():
    relay, email, password = sys.argv[1], sys.argv[2], sys.argv[3]
    http = relay.replace("ws://", "http://").replace("wss://", "https://")

    # 1. 登录
    auth = http_json(f"{http}/api/login", {"email": email, "password": password})
    token = auth["token"]
    print("[phone] 登录成功:", auth["user"]["email"])

    async with websockets.connect(f"{relay}/ws/phone?token={token}") as ws:
        # 心跳：每 25s 发一次 ping，防止被中继踢下线
        async def keepalive():
            while True:
                await asyncio.sleep(25)
                try:
                    await ws.send(json.dumps({"type": "ping"}))
                except websockets.ConnectionClosed:
                    return

        ping_task = asyncio.create_task(keepalive())
        # 2. 设备列表
        first = json.loads(await asyncio.wait_for(ws.recv(), 10))
        assert first["type"] == "device.list", first
        online = [d for d in first["devices"] if d["online"]]
        print("[phone] 设备:", [(d["name"], d["online"]) for d in first["devices"]])
        assert online, "没有在线设备"
        dev = online[0]
        device_id = dev["id"]

        async def cmd(req_id: str, path: str, method: str = "GET", body=None):
            await ws.send(json.dumps({
                "type": "cmd", "id": req_id, "deviceID": device_id,
                "cmd": {"method": method, "path": path, "body": body},
            }))

        async def wait_result(req_id: str, timeout=120):
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout))
                if msg.get("type") == "cmd.result" and msg.get("id") == req_id:
                    return msg

        # 3. 会话列表
        await cmd("r1", "/session")
        r = await wait_result("r1")
        sessions = r.get("data") or []
        print(f"[phone] 会话列表: {len(sessions)} 个")

        # 4. 新建会话并发消息（走 prompt_async，内容走事件流）
        await cmd("r2", "/session", "POST", {"title": "手机端联调"})
        r = await wait_result("r2")
        sid = r["data"]["id"]
        print("[phone] 新建会话:", sid)

        await cmd("r3", f"/session/{sid}/prompt_async", "POST",
                  {"parts": [{"type": "text", "text": "你好，只回复OK两个字，不要做其他事"}]})
        r = await wait_result("r3")
        print("[phone] prompt_async:", r["ok"])

        # 5. 等流式事件（text 累计 + 任务结束）
        got_text, got_idle = "", False
        while not got_idle:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 60))
            if msg.get("type") == "event":
                ev = msg["event"]
                if ev["type"] == "message.part.updated" and ev["properties"]["part"]["type"] == "text":
                    got_text = ev["properties"]["part"].get("text") or ""
                elif ev["type"] == "session.idle" and ev["properties"]["sessionID"] == sid:
                    got_idle = True
        print(f"[phone] 流式回复: '{got_text}'")

        # 6. 权限审批（MiniAgent 无工具则跳过）：bash 触发权限请求
        await cmd("r4", f"/session/{sid}/prompt_async", "POST",
                  {"parts": [{"type": "text", "text": "回复: 你好，这是一次远程测试"}]})
        permission_id = None
        try:
            while permission_id is None:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 20))
                if msg.get("type") == "event":
                    ev = msg["event"]
                    if ev["type"] in ("permission.asked", "permission.ask"):
                        permission_id = ev["properties"].get("id")
                        print("[phone] 收到权限请求:", ev["properties"].get("permission"),
                              ev["properties"].get("metadata") or ev["properties"].get("patterns"))
                        break
        except asyncio.TimeoutError:
            print("[phone] 无权限请求（Agent 无工具，跳过审批）")
        if permission_id:
            await cmd("r5", f"/session/{sid}/permissions/{permission_id}", "POST", {"response": "once"})
            r = await wait_result("r5", timeout=30)
            print("[phone] 权限响应(once):", r["ok"])

        # 7. 等任务完成，验证文件确实被写入（授权生效）
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 90))
            if msg.get("type") == "event" and msg["event"]["type"] == "session.idle":
                break
        print("[phone] 任务完成 ✅")
        ping_task.cancel()
        print("[phone] ALL PASS")


asyncio.run(main())
