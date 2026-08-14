"""relay WS 路由自测：模拟手机端 + 电脑端。

用法: python test_ws.py <jwt> <deviceToken> [relayUrl]
"""
import asyncio
import json
import sys

import websockets

RELAY = sys.argv[3] if len(sys.argv) > 3 else "ws://localhost:8080"


async def phone_main(jwt: str, dev_id: str):
    async with websockets.connect(f"{RELAY}/ws/phone?token={jwt}") as ws:
        first = json.loads(await asyncio.wait_for(ws.recv(), 5))
        print("[phone] recv:", json.dumps(first)[:120])
        assert first["type"] == "device.list", "首帧应为 device.list"

        # 1. 发指令 → 应转发到设备
        await ws.send(json.dumps({
            "type": "cmd", "id": "req_001", "deviceID": dev_id,
            "cmd": {"method": "GET", "path": "/global/health"},
        }))
        # 2. 等设备回 cmd.result
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 10))
            if msg["type"] == "cmd.result" and msg["id"] == "req_001":
                print("[phone] cmd.result ok=", msg["ok"], "data=", msg.get("data"))
                break
        # 3. 等设备广播事件
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 10))
            if msg["type"] == "event":
                print("[phone] event:", json.dumps(msg["event"])[:100])
                break
        # 4. 等设备离线通知
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), 10))
            if msg["type"] == "device.online" and not msg["online"]:
                print("[phone] device offline notified")
                break
        # 5. 对离线设备发指令 → 应立刻返回错误
        await ws.send(json.dumps({
            "type": "cmd", "id": "req_002", "deviceID": dev_id,
            "cmd": {"method": "GET", "path": "/global/health"},
        }))
        msg = json.loads(await asyncio.wait_for(ws.recv(), 5))
        assert msg["type"] == "cmd.result" and not msg["ok"], "离线设备应返回错误"
        print("[phone] offline cmd rejected:", msg["error"])
        print("[phone] ALL PASS")


async def device_main(dev_token: str):
    async with websockets.connect(f"{RELAY}/ws/device?token={dev_token}") as ws:
        msg = json.loads(await asyncio.wait_for(ws.recv(), 5))
        assert msg["type"] == "cmd" and msg["cmd"]["path"] == "/global/health", msg
        print("[device] got cmd:", msg["id"], msg["cmd"]["path"])
        await ws.send(json.dumps({
            "type": "cmd.result", "id": msg["id"], "ok": True,
            "data": {"healthy": True, "version": "1.18.18"},
        }))
        await ws.send(json.dumps({
            "type": "event",
            "event": {"type": "message.part.updated", "properties": {"part": {"type": "text", "text": "hi"}}},
        }))
        print("[device] replied + event sent, closing...")
        await ws.close()


async def main():
    jwt = sys.argv[1]
    import urllib.request

    http = RELAY.replace("ws", "http")
    req = urllib.request.Request(
        f"{http}/api/devices",
        method="POST",
        headers={"Authorization": f"Bearer {jwt}", "Content-Type": "application/json"},
        data=json.dumps({"name": "WS test device"}).encode(),
    )
    with urllib.request.urlopen(req) as r:
        dev = json.loads(r.read())
    dev_id, dev_token = dev["deviceID"], dev["deviceToken"]
    print("registered device:", dev_id)
    await asyncio.gather(
        phone_main(jwt, dev_id),
        device_main(dev_token),
    )


asyncio.run(main())
