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
git clone https://github.com/flying-nimbus-frog/agentpilot.git && cd agentpilot/relay \
  && cp .env.example .env \
  && sed -i "s/RELAY_JWT_SECRET=.*/RELAY_JWT_SECRET=$(openssl rand -hex 32)/" .env \
  && docker compose up -d --build
```

`.env.example` 是配置模板（所有可配置项+注释），复制为 `.env` 后填写真实值：

- **必填**：`RELAY_JWT_SECRET`（JWT 签名密钥）
- **可选**：`RELAY_PORT`、`RELAY_CORS`、`RELAY_DB`
- **邮件**（邮箱验证/密码找回）：`RELAY_SMTP_HOST/PORT/USER/PASS`、`RELAY_MAIL_FROM`、`RELAY_PUBLIC_BASE`

> `.env` 已被 `.gitignore` 排除，永远不会提交到仓库。

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

## 邮件（邮箱验证 / 密码找回）

中继需要 SMTP 发信（.env 或环境变量）：

```
RELAY_SMTP_HOST=smtp.example.com
RELAY_SMTP_PORT=465          # 465=SSL, 587=STARTTLS
RELAY_SMTP_USER=no-reply@yourdomain.com
RELAY_SMTP_PASS=********
RELAY_MAIL_FROM=no-reply@yourdomain.com
RELAY_PUBLIC_BASE=https://relay.zhileai.net
```

未配置 SMTP 时：验证/重置链接打印到容器日志（仅开发用）。国内可选阿里云邮件推送、SendGrid 等。

## APNs 推送通知（审批/补充信息/任务完成提醒）

### 前置：Apple 开发者后台申请凭据

1. **Team ID**：developer.apple.com → 头像 → Membership Details
2. **APNs Auth Key (.p8)**：Certificates, Identifiers & Profiles → Keys → 新建 Key →
   勾选 **Apple Push Notifications service (APNs)** → Download（**只能下载一次，妥善保存**）
3. **Key ID**：Keys 列表点该 Key 查看
4. 确认 App ID（如 `net.zhileai.agentpilot`）的 **Push Notifications** 能力已开启

### 配置（.env）

```
RELAY_APNS_KEY_PATH=/opt/opencode-phone-prototype/relay/AuthKey_XXXXXXXXXX.p8
RELAY_APNS_KEY_ID=XXXXXXXXXX          # Key ID
RELAY_APNS_TEAM_ID=XXXXXXXXXX         # Team ID
RELAY_APNS_TOPIC=net.zhileai.agentpilot  # App Bundle ID
RELAY_APNS_URL=https://api.push.apple.com
```

### ⚠️ 沙盒 / 生产环境切换（必读）

| App 签名方式 | APNs 环境 | RELAY_APNS_URL |
|-------------|----------|----------------|
| 开发签名（Xcode 直装 / 个人免费账号） | **沙盒** | `https://api.sandbox.push.apple.com` |
| TestFlight / App Store（生产签名） | **生产** | `https://api.push.apple.com`（默认） |

**环境不匹配时 APNs 返回 `BadDeviceToken`，推送静默失败**——这是最常见的坑。

### 触发时机（中继自动推送）

| 事件 | 推送内容 | 前台表现 | 后台/锁屏 |
|------|---------|---------|----------|
| `permission.asked` | 需要你的授权 / 需要补充信息 | 应用内震动+弹窗 | 系统横幅 |
| `session.idle` | 任务完成 | 静默 | 系统横幅 |

### 验证

```bash
# 1. 确认服务端就绪
curl -X POST https://你的域名/api/push/register -H "Authorization: Bearer <jwt>" -H "Content-Type: application/json" -d '{"token":"x"}'  # pushEnabled 应为 true

# 2. 手机登录 → 授权通知 → App 自动注册 APNs token

# 3. 触发一次授权请求（如 bash:ask），锁屏手机应收到横幅

# 4. 服务器日志排查
docker logs ocrelay --tail 60 2>&1 | grep apns
#   推送成功: [apns] 推送成功
#   BadDeviceToken: 环境不匹配或 token 过期
