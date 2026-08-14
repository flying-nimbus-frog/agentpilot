# OpenCode Remote 中继服务器（relay）

云端账号 + 消息中继。手机端和电脑端都连到它。

## 本地开发

```bash
cd relay
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
RELAY_PORT=8080 .venv/bin/python main.py
```

- 健康检查: `GET http://localhost:8080/health`
- API 文档: `http://localhost:8080/docs`
- 数据: 默认 `relay/relay.db`（可用 `RELAY_DB` 环境变量改路径）
- 密钥: `RELAY_JWT_SECRET`（生产必须设置，否则 token 可被伪造）

## 生产部署（Docker）

```bash
docker build -t opencode-relay .
mkdir -p /data/ocrelay
docker run -d --name ocrelay --restart always \
  -p 8000:8000 \
  -v /data/ocrelay:/data \
  -e RELAY_JWT_SECRET="$(openssl rand -hex 32)" \
  -e RELAY_DB=/data/relay.db \
  opencode-relay
```

## 生产部署（systemd + 裸机）

```bash
sudo useradd -r -m ocrelay
sudo -u ocrelay bash -c 'cd /opt/ocrelay && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt'
```

`/etc/systemd/system/ocrelay.service`:

```ini
[Unit]
Description=OpenCode Remote Relay
After=network.target

[Service]
User=ocrelay
WorkingDirectory=/opt/ocrelay
Environment=RELAY_JWT_SECRET=<随机长字符串>
ExecStart=/opt/ocrelay/.venv/bin/python main.py
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now ocrelay
```

## TLS（必做）

中继必须走 HTTPS/WSS。用 Caddy 最简单：

```nginx
relay.example.com {
    reverse_proxy 127.0.0.1:8000
}
```

Caddy 自动申请证书，`http://` 自动重定向 `https://`。

## 防火墙

开放 443（TLS 由 Caddy 终止）。8000 不要直接暴露公网。

## 测试

```bash
# REST
curl -X POST http://localhost:8000/api/register -H 'Content-Type: application/json' \
  -d '{"email":"a@b.com","password":"123456"}'

# WS 路由自测（模拟手机+设备）
.venv/bin/python test_ws.py <jwt>

# 手机端全链路（需 companion 在线）
.venv/bin/python test_phone.py ws://localhost:8080 a@b.com 123456
```
