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

## 生产部署（Docker Compose，推荐）

```bash
# 首次（含克隆代码 + 生成密钥 + 拉起，依赖走国内镜像）
git clone https://github.com/你的用户名/agentpilot.git && cd agentpilot/relay && echo "RELAY_JWT_SECRET=$(openssl rand -hex 32)" > .env && docker compose up -d --build

# 之后重启/更新
docker compose up -d --build

# 查看状态
docker compose ps && curl http://localhost:8010/health
```

- 宿主端口默认 **8010**（8080 可能被占用），可用环境变量改：`RELAY_PORT=9000 docker compose up -d`
- 数据（SQLite）持久化在 Docker 卷 `ocrelay-data`
- `RELAY_JWT_SECRET` 从 `.env` 读取，必须设置（启动前未设置会直接报错，防止默认密钥上线）
- **国内加速已内置**：pip 依赖默认走清华源 `pypi.tuna.tsinghua.edu.cn`（`.env` 里加 `PIP_INDEX_URL=` 可覆盖）；基础镜像可用 `PYTHON_IMAGE=docker.m.daocloud.io/library/python:3.12-slim` 覆盖

### 基础镜像拉取太慢？配置 Docker 国内镜像仓库（服务器一次性）

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live",
    "https://hub.rat.dev"
  ]
}
EOF
sudo systemctl restart docker
```

配置后重新 `docker compose up -d --build`，基础镜像 `python:3.12-slim` 会从国内镜像仓秒拉。

## 生产部署（Docker 单容器）

```bash
docker build -t opencode-relay .
mkdir -p /data/ocrelay
docker run -d --name ocrelay --restart always \
  -p 8010:8000 \
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
Environment=RELAY_PORT=8010
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

开放 **8010/TCP**（若用 Caddy 反代则只开 443，8010 不要直接暴露公网）。

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
