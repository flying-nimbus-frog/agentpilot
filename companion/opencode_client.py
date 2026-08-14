"""本地 opencode serve 的异步 HTTP 客户端。"""
import json

import httpx


class OpenCodeClient:
    def __init__(self, host: str, port: int, password: str):
        self.base = f"http://{host}:{port}"
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(120.0),
            headers={"Authorization": f"Basic {_b64('opencode:' + password)}"},
        )

    async def aclose(self):
        await self._client.aclose()

    async def request(self, method: str, path: str, body: dict | None = None) -> dict:
        """执行 opencode REST 指令，返回 {ok, data|error}。"""
        try:
            res = await self._client.request(
                method.upper(),
                f"{self.base}{path}",
                json=body if body else None,
            )
        except httpx.HTTPError as e:
            return {"ok": False, "error": f"本地 opencode 请求失败: {e}"}
        if res.status_code == 204:
            return {"ok": True, "data": None}
        try:
            data = res.json()
        except ValueError:
            data = {"raw": res.text[:500]}
        if res.is_error:
            return {"ok": False, "error": f"HTTP {res.status_code} {path}: {json.dumps(data, ensure_ascii=False)[:300]}"}
        return {"ok": True, "data": data}

    async def health(self) -> dict:
        return await self.request("GET", "/global/health")

    async def events(self):
        """异步 SSE 流，yield 原始 event JSON dict。"""
        url = f"{self.base}/event"
        try:
            async with self._client.stream("GET", url) as res:
                res.raise_for_status()
                buf = ""
                async for chunk in res.aiter_text():
                    buf += chunk
                    while "\n\n" in buf:
                        raw_event, buf = buf.split("\n\n", 1)
                        for line in raw_event.splitlines():
                            if line.startswith("data: "):
                                try:
                                    yield json.loads(line[6:])
                                except json.JSONDecodeError:
                                    pass
                                break
        except httpx.HTTPError as e:
            print(f"[companion] SSE 流中断: {e}")


def _b64(s: str) -> str:
    import base64

    return base64.b64encode(s.encode()).decode()
