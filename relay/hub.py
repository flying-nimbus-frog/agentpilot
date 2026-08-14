import asyncio
import json
import logging

import db

log = logging.getLogger("relay.hub")


class Hub:
    """内存中的连接注册表：账号 → 手机连接；设备ID → 设备连接。"""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._phones: dict[str, set] = {}  # user_id -> {WebSocket}
        self._devices: dict[str, dict] = {}  # device_id -> {ws, user_id, name}

    # ---------- 连接管理 ----------

    async def phone_connect(self, user_id: str, ws) -> None:
        async with self._lock:
            self._phones.setdefault(user_id, set()).add(ws)

    async def phone_disconnect(self, user_id: str, ws) -> None:
        async with self._lock:
            s = self._phones.get(user_id)
            if s:
                s.discard(ws)
                if not s:
                    self._phones.pop(user_id, None)

    async def device_connect(self, device_id: str, user_id: str, name: str, ws) -> None:
        async with self._lock:
            self._devices[device_id] = {"ws": ws, "user_id": user_id, "name": name}
        await self.broadcast(
            user_id,
            {"type": "device.online", "deviceID": device_id, "online": True},
        )

    async def device_disconnect(self, device_id: str) -> None:
        async with self._lock:
            entry = self._devices.pop(device_id, None)
        if entry:
            await self.broadcast(
                entry["user_id"],
                {"type": "device.online", "deviceID": device_id, "online": False},
            )

    # ---------- 路由 ----------

    def is_device_online(self, device_id: str) -> bool:
        return device_id in self._devices

    def get_device(self, device_id: str) -> dict | None:
        return self._devices.get(device_id)

    async def send_to_device(self, device_id: str, msg: dict) -> bool:
        entry = self._devices.get(device_id)
        if not entry:
            return False
        try:
            await entry["ws"].send_text(json.dumps(msg))
            return True
        except Exception:
            return False

    async def broadcast(self, user_id: str, msg: dict) -> None:
        payload = json.dumps(msg)
        async with self._lock:
            conns = list(self._phones.get(user_id, set()))
        for ws in conns:
            try:
                await ws.send_text(payload)
            except Exception:
                pass

    # ---------- 手机端下发设备列表 ----------

    async def device_list_for_phone(self, user_id: str) -> list[dict]:
        out = []
        for d in db.list_devices(user_id):
            entry = self._devices.get(d["id"])
            out.append(
                {
                    "id": d["id"],
                    "name": d["name"],
                    "online": entry is not None,
                    "status": d.get("status", "active"),
                    "version": d.get("version"),
                    "lastSeen": d["last_seen"],
                }
            )
        return out


hub = Hub()
