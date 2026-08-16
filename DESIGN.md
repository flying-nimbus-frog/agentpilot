# OpenCode Remote V2 · 云端中继 + 账号体系 设计文档

> 版本：v2.0（2026-08-14）
> 状态：设计定稿，代码实现中
> 对应 v1（局域网 + Expo）已废弃，归档于 `v1-expo/`。v1 实测得到的 opencode 协议细节全部复用。

---

## 1. 目标与变化

v1 的两大痛点：

| v1 问题 | V2 方案 |
|---------|---------|
| 只能在局域网内用 | 走**云端中继服务器**，任何网络都能连 |
| 没有账号体系，谁拿到密码都能连 | **账号体系**：邮箱+密码注册登录，手机端和电脑端绑定同一账号 |
| Expo 开发体验差 | 手机端改用 **Flutter**（用户自选） |
| 手机必须知道电脑 IP/密码 | 手机只需登录账号，自动发现账号下的电脑设备 |

核心使用场景：

```
手机(登录A账号) ──▶ 看到账号A名下的电脑设备 ──▶ 选一台设备 ──▶ 指挥它干活
                                                                 ▲
电脑(登录A账号) ◀── 收到指令 → 执行 opencode 任务 ──────────────┘
                  事件/进度实时推回手机，权限请求在手机上审批
```

---

## 2. 总体架构

```
┌──────────┐   HTTPS/WSS    ┌───────────────────┐   WSS    ┌──────────────────┐
│ 手机 App  │ ─────────────▶│  云端中继服务器     │◀─────────│ 电脑端伴侣守护进程 │
│ (Flutter)│ ◀─────────────│  (relay, Python)   │──────────▶│ (companion,Python)│
└──────────┘   REST+WS      └───────────────────┘   WSS     └────────┬─────────┘
    │ 账号/设备/指令/事件        │ 账号体系(JWT)                     │ 本机 HTTP + SSE
    │                            │ 设备注册/在线状态                  │
    │                            │ 消息路由(指令/事件)                │
    │                            └───────────────────┬───────────────┘
    │                                                │
    │                                        opencode serve (localhost)
    │                                        ┌──────▼──────┐
    │                                        │ 项目文件/工具│
    └──────────── 手机也可以多台，同一账号共享 ──┴─────────────┘
```

**角色职责：**

| 组件 | 职责 | 技术 |
|------|------|------|
| **中继服务器 relay** | 账号注册/登录、设备注册、连接保活、指令路由、事件广播、离线队列（可选） | Python 3.12 + FastAPI + WebSocket + SQLite |
| **电脑端伴侣 companion** | 守护进程：拉起本机 `opencode serve`、代理 REST 指令、把 opencode 的 SSE 事件转发到中继 | Python 3.12 + asyncio + websockets + httpx |
| **手机 App mobile** | 登录、设备列表、会话列表、实时聊天、权限审批 | Flutter（单代码库 iOS/Android） |

**核心原则：中继只做"路由和转发"，不懂 opencode 语义。**
指令是"原样代理"到电脑端本地 opencode HTTP API；事件是"原样转发"opencode 的 SSE。这样 opencode 升级协议时，客户端和伴侣都不用改语义逻辑。

---

## 3. 账号体系设计

### 3.1 账号

- 注册：邮箱 + 密码（密码 pbkdf2 加盐哈希，不存明文）
- 登录：返回 JWT（短期 access token，含用户 ID）
- 一个账号下可绑定**多台电脑设备**、多个手机

### 3.2 设备（电脑端）

- 电脑端伴侣首次运行：`companion --login`（输入邮箱密码）→ 向中继注册设备 → 获得**设备令牌**（长随机串）保存本地
- 设备令牌是设备的长期身份凭证，用于 WS 长连接鉴权；设备离线时服务器保留注册信息，仅标记离线
- 设备令牌泄露可远程吊销（v2.1 迭代：中继提供设备管理页/接口）

### 3.3 手机端

- 手机 App 登录账号 → WS 连接用 JWT 鉴权 → 服务器为该连接绑定账号
- 手机天然能"看到"账号下所有设备及其在线状态（设备心跳推送）

### 3.4 安全

- 全部走 TLS（HTTPS/WSS），中继部署时用反向代理（Caddy/nginx）终结 TLS
- 手机→中继、电脑→中继之间传输的指令和事件**端到端无中间解密**（v2.1 可选加 E2E 加密，令牌协商）
- 密码 pbkdf2 100k 轮；JWT HS256，密钥存环境变量

---

## 4. 通信协议（详见 PROTOCOL.md）

### 4.1 REST（中继）

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/register` | `{email, password}` → `{token, user}` |
| POST | `/api/login` | `{email, password}` → `{token, user}` |
| GET | `/api/devices` | Bearer JWT → 设备列表（含在线状态） |
| POST | `/api/devices` | Bearer JWT → 注册当前电脑设备，返回 `{deviceID, deviceToken}` |
| POST | `/api/devices/:id/pair` | 手机端主动配对（v2.1） |
| GET | `/health` | 健康检查 |

### 4.2 WebSocket

手机端 `/ws/phone?token=<JWT>`，电脑端 `/ws/device?token=<deviceToken>`。

统一 JSON 信封：

```jsonc
// 手机 → 电脑（经中继）：执行 opencode HTTP 指令
{ "type": "cmd", "id": "req_xxx", "deviceID": "dev_xxx",
  "cmd": { "method": "GET|POST", "path": "/session", "body": {...} } }

// 电脑 → 手机：指令结果
{ "type": "cmd.result", "id": "req_xxx", "ok": true, "data": {...} }
{ "type": "cmd.result", "id": "req_xxx", "ok": false, "error": "设备离线" }

// 电脑 → 手机：opencode 实时事件（原样转发 SSE 内容）
{ "type": "event", "event": { "type": "message.part.updated", "properties": {...} } }

// 状态类
{ "type": "device.online", "deviceID": "dev_xxx", "online": true }
{ "type": "device.list", "devices": [...] }   // 手机连上后下发一次
{ "type": "pong" }                             // 心跳
```

### 4.3 指令映射（手机 App 用，与 v1 实测一致）

| 用途 | method/path（转发到电脑本地 opencode） |
|------|----------------------------------------|
| 会话列表 | `GET /session` |
| 发消息（流式） | `POST /session/:id/prompt_async` + 事件流 |
| 消息历史 | `GET /session/:id/message?limit=N` |
| 中止 | `POST /session/:id/abort` |
| 权限响应 | `POST /session/:id/permissions/:permissionID` body `{response: once\|always\|reject}` |
| 新建会话 | `POST /session` |
| 状态 | `GET /session/status` |
| 健康/版本 | `GET /global/health` |

---

## 5. 手机 App 页面设计（Flutter）

```
登录/注册 → 设备列表 → 会话列表 → 聊天
                            └─ 权限审批卡片（模态）
```

| 页面 | 内容 |
|------|------|
| 登录页 | 邮箱+密码登录 / 注册切换；JWT 存 shared_preferences |
| 设备列表 | 账号下所有电脑设备 + 在线状态（绿/灰）；选中后进入 |
| 会话列表 | 该电脑的会话 + 运行状态；新建会话 |
| 聊天页 | 流式消息、工具调用卡片、中止按钮；权限到达弹审批卡片（允许一次/总是允许/拒绝） |
| 连接状态 | 顶部显示 WS 连接状态，断线自动重连 |

---

## 6. 项目结构

```
agentpilot/
├── DESIGN.md              # 本文档
├── PROTOCOL.md            # 通信协议详细契约（手机端实现者必读）
├── v1-expo/               # v1 归档（废弃）
├── relay/                 # 云端中继服务器
│   ├── main.py            # FastAPI：REST 账号 + WS 路由 + 心跳
│   ├── auth.py            # pbkdf2 密码 + JWT
│   ├── db.py              # SQLite（users / devices）
│   ├── hub.py             # 连接注册表 + 路由
│   ├── test_ws.py         # WS 路由自测
│   ├── test_phone.py      # 手机端全链路模拟
│   ├── requirements.txt / Dockerfile
│   └── README.md          # 部署说明（Docker / systemd / Caddy TLS）
├── companion/             # 电脑端伴侣
│   ├── main.py            # CLI: login / run（守护进程）
│   ├── opencode_client.py # 本地 opencode HTTP + SSE 客户端
│   ├── config.py          # ~/.config/opencode-remote/companion.json
│   └── requirements.txt / README.md
└── mobile/                # Flutter 手机端
    ├── pubspec.yaml
    └── lib/
        ├── main.dart      # 入口 + 登录态恢复
        ├── api/{protocol,relay}.dart
        ├── screens/{login,devices,sessions,chat}_screen.dart
        ├── widgets/{message_bubble,permission_card}.dart
        └── store/session_store.dart
```

## 7. 开发计划

| 阶段 | 内容 | 状态 |
|------|------|------|
| D1 | 设计定稿（DESIGN.md + PROTOCOL.md） | ✅ 完成 |
| D2 | 中继服务器 + WS 路由自测 | ✅ 完成 |
| D3 | 电脑端伴侣 + 端到端联调（模拟手机：登录/流式/权限审批全通过） | ✅ 完成 |
| D4 | Flutter 手机端代码 | ✅ 完成（`flutter analyze` 零问题，冒烟测试通过） |
| D5 | 服务器部署 + 真机验收 | 待用户部署后验证 |

---

## 8. 风险与开放问题

| 项 | 说明 | 应对 |
|----|------|------|
| 中继是单点 | 中继挂了手机和电脑都失联 | v2.1 支持多中继地址；电脑端离线不丢任务（opencode 本地继续跑） |
| 指令带宽 | 聊天流式内容经中继转发 | 文本量级，可接受；大文件传输 v2.1 走直连/对象存储 |
| 手机后台保活 | iOS/Android 杀后台后 WS 断开 | v2.1 接推送（APNs/厂商通道）由中继触发"权限请求"通知 |
| Flutter 环境 | 本机未装 Flutter SDK | 手机端交付源码 + 安装指引，用户本机 `flutter run` |
| 服务器地址 | 用户云服务器地址未提供 | relay 支持 `RELAY_URL`/`--relay` 参数，部署时填入 |
