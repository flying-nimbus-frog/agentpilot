# OpenCode Remote V2 · 通信协议契约

> 手机端实现者、中继、电脑端三方共同遵守的协议。
> 所有消息均为 UTF-8 JSON，WS 帧为文本帧。

## 1. 基础约定

- 服务器地址：`https://<host>`（REST）/ `wss://<host>`（WS），本地开发用 `http://` / `ws://`
- 默认端口：8000（可配置）
- 时间字段：毫秒时间戳
- ID 生成：客户端用 UUID

## 2. REST 接口

### 2.1 注册

```
POST /api/register
Body: { "email": "a@b.com", "password": "******" }
200 → { "token": "<jwt>", "user": { "id": "usr_xxx", "email": "a@b.com" } }
409 → { "detail": "邮箱已注册" }
```

### 2.2 登录

```
POST /api/login
Body: { "email": "a@b.com", "password": "******" }
200 → { "token": "<jwt>", "user": { "id", "email", "emailVerified" } }
401 → { "detail": "邮箱或密码错误" }
```

### 2.3 账号安全（邮箱验证 / 找回密码 / 会话吊销）

```
GET  /api/verify?token=<vt>                  # 邮箱验证（邮件链接）
POST /api/forgot-password {email}            # 发送重置邮件（防枚举，恒返回成功）
POST /api/reset-password {token, password}   # 重置密码（成功后吊销所有会话）
POST /api/sessions/revoke                    # 登出所有设备（Bearer JWT）
```

- 注册后 `emailVerified=false`，验证后为 true
- JWT 含 `ver`（会话版本）；吊销/重置密码后版本 +1，旧 token 立即 401
- 验证/重置令牌为一次性 JWT：验证 24h 有效，重置 1h 有效

### 2.3 设备列表（手机端）

```
GET /api/devices
Header: Authorization: Bearer <jwt>
200 → { "devices": [
  { "id": "dev_xxx", "name": "MacBook", "online": true,
    "lastSeen": 1786683815667, "version": "1.18.18" } ] }
```

### 2.4 设备注册（电脑端伴侣，含配对码）

```
POST /api/devices
Header: Authorization: Bearer <jwt>
Body: { "name": "MacBook Air" }
200 → { "pendingID": "dev_xxx", "pendingToken": "pt_xxx",
        "pairingCode": "265890", "expiresIn": 600 }
```

设备不直接激活，需手机确认配对：

```
GET /api/devices/:id/status?token=<pendingToken>      # 电脑端轮询(每3s)
200 → { "status": "pending" } | { "status": "active", "deviceToken": "dt_xxx" }

POST /api/devices/:id/pair                            # 手机端确认
Header: Authorization: Bearer <jwt>
Body: { "code": "265890" }
200 → { "deviceID": "dev_xxx", "deviceToken": "dt_xxx" }
401 → 配对码错误
410 → 已过期（10 分钟）| 404 → 不存在
```

配对码 10 分钟有效；设备列表返回 `status: pending|active`，App 对 pending 设备展示"配对"入口。

### 2.5 设备管理

```
GET    /api/devices            # 列表（含 status）
DELETE /api/devices/:id        # 删除离线设备（400 若在线）
```

### 2.6 限流

| 接口 | 限制 |
|------|------|
| POST /api/register | 5 次/小时/IP |
| POST /api/login | 10 次/分钟/IP（成功后重置） |
| POST /api/devices/:id/pair | 5 次/分钟/IP |
| 全局兜底 | 600 次/分钟/IP |

## 3. WebSocket 通道

### 3.1 手机端

```
WS /ws/phone?token=<jwt>
```

- 连上后服务器先发一条 `device.list`
- 设备上下线实时推送 `device.online`

### 3.2 电脑端

```
WS /ws/device?token=<deviceToken>
```

- 连接成功即视为设备上线；断开即离线

### 3.3 心跳

双方每 30s 发 `{"type":"ping"}`，对端回 `{"type":"pong"}`；60s 无任何消息判为离线。

## 4. 消息类型

### 4.1 手机 → 中继 → 电脑：`cmd`

```json
{
  "type": "cmd",
  "id": "req_<uuid>",          // 请求 ID，结果原样带回
  "deviceID": "dev_xxx",       // 目标设备
  "cmd": {
    "method": "POST",          // GET | POST | PATCH | DELETE
    "path": "/session/xxx/prompt_async",
    "body": { "parts": [ { "type": "text", "text": "hi" } ] }  // GET 时可为空
  }
}
```

中继校验：设备在线 → 转发；离线 → 直接回 `cmd.result` with `ok:false, error:"设备离线"`。

### 4.2 电脑 → 中继 → 手机：`cmd.result`

```json
{ "type": "cmd.result", "id": "req_<uuid>", "ok": true, "data": { ... } }
{ "type": "cmd.result", "id": "req_<uuid>", "ok": false, "error": "HTTP 401 ..." }
```

`data` 即电脑本地 opencode HTTP 的 JSON 响应体（204 时为 `null`）。

### 4.3 电脑 → 中继 → 手机：`event`

opencode SSE 事件原样转发（含内部结构，不做语义解析）：

```json
{ "type": "event", "event": { "type": "message.part.updated", "properties": { ... } } }
```

### 4.4 状态类

```json
{ "type": "device.list", "devices": [...] }
{ "type": "device.online", "deviceID": "dev_xxx", "online": true }
{ "type": "ping" } / { "type": "pong" }
{ "type": "error", "code": "AUTH_FAILED", "message": "..." }
```

## 5. 指令与 opencode API 映射（手机端）

手机端只需关心"发指令 + 收事件"，具体语义：

| 用途 | cmd.method / cmd.path | body | 事件补充 |
|------|-----------------------|------|----------|
| 设备版本 | GET `/global/health` | - | - |
| 会话列表 | GET `/session` | - | - |
| 会话状态 | GET `/session/status` | - | - |
| 新建会话 | POST `/session` | `{"title":"..."}` | - |
| 消息历史 | GET `/session/:id/message?limit=200` | - | - |
| 发送消息 | POST `/session/:id/prompt_async` | `{"parts":[{"type":"text","text":"..."}]}` | 流式内容走 `event`（`message.part.updated`） |
| 中止 | POST `/session/:id/abort` | - | `session.status`/`session.idle` |
| 权限响应 | POST `/session/:id/permissions/:permissionID` | `{"response":"once"\|"always"\|"reject"}` | - |
| 会话删除 | DELETE `/session/:id` | - | - |

## 6. 手机端需处理的 opencode 事件（v1.18.18 实测）

| event.type | 关键字段 | 手机端动作 |
|------------|----------|-----------|
| `message.part.updated` | `properties.part`（`messageID`,`id`,`type`,`text` 累计全文） | 按 part.id 更新聊天内容 |
| `permission.asked` | `properties.id`(=permissionID), `properties.permission`(工具), `properties.metadata`/`patterns` | 弹审批卡片；回复走 4.4 权限响应 cmd |
| `session.status` | `properties.status.type`（busy/idle/error） | 更新运行状态 |
| `session.idle` / `session.error` | `properties.sessionID` | 任务结束 → 刷新消息 |
| `session.updated` | `properties.info` | 可选：刷新会话列表 |
| 其他（`plugin.added` 等） | - | 忽略 |

注意事项（踩坑记录）：
- 权限响应值只有 `once` / `always` / `reject`，不是 allow/deny
- tool part 的 `state` 是对象 `{status,input,time,output}`
- `message.part.updated` 的 `messageID` 在 **part 对象内部**，不在 properties 顶层
- 事件名兼容 `permission.asked`（老版本 `permission.ask`）
