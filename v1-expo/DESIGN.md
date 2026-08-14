# OpenCode 手机遥控器（Mobile Remote）设计文档

> 版本：v0.1（原型阶段）
> 日期：2026-08-14
> 状态：设计评审 + 原型实现中

---

## 1. 背景与目标

### 1.1 问题

用户在使用 opencode（桌面版 / TUI）执行任务时，必须长时间守在电脑前：

- 任务中途会弹出权限审批（允许/拒绝某条命令、某个文件修改）
- 有时需要补充信息、调整方案、回答 agent 的问题
- 无法离开电脑，也无法在手机上进行这些决策

### 1.2 目标

在手机上运行一个 **原生 App**，通过局域网或 VPN 直连电脑上运行的 opencode，让用户：

1. **查看**电脑上 opencode 的运行状态、会话进度（实时）
2. **指挥**——在手机上直接给 opencode 下发新指令、继续对话
3. **决策**——在手机上审批权限请求（允许/拒绝/记住选择）、回答 agent 提出的问题

### 1.3 非目标（本次不做）

- 不做代码浏览/文件编辑器（openode TUI/IDE 已覆盖）
- 不做多用户/团队协作、不做云端账号体系
- 不做 opencode 服务器端改造（保持官方协议兼容，纯客户端方案）

---

## 2. 总体架构

```
┌─────────────┐        局域网 / Tailscale         ┌──────────────────────┐
│  手机 App    │  ─────  HTTP REST + SSE  ──────▶  │   电脑 (macOS)        │
│ (Expo/RN)   │  ◀──────────────────────────────  │  opencode Server      │
└─────────────┘   EventSource 实时事件流           │  (serve / 桌面版)     │
                                                  └──────────────────────┘
                                                          │ 控制
                                                   ┌──────▼──────┐
                                                   │ 项目目录/文件│
                                                   └─────────────┘
```

**核心思想：手机 App 只是 opencode 的另一个客户端。**

opencode 本身是"服务端 + 多客户端"架构（官方 TUI、IDE 插件、Web UI 都是客户端），
服务端暴露完整的 HTTP API（OpenAPI 3.1）。手机 App 复用这套协议，零服务端改造。

### 2.1 两种对接模式

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| A. 桌面版直连 | opencode 桌面版自身内嵌 server，若其支持将监听地址绑定到 `0.0.0.0` 则手机直接连它，会话与桌面版完全一致 | 优先目标（待验证桌面版是否支持局域网绑定） |
| B. 伴侣服务 | 电脑上额外启动 `opencode serve --hostname 0.0.0.0`，手机连伴侣服务 | **原型采用** |

> 实测结果（v1.18.18）：模式 B 的 `serve` 与桌面版**共享同一数据库**
> （`~/.local/share/opencode/opencode.db`），因此会话列表、模型凭据完全互通——
> 手机上看到的正是桌面版里正在跑的会话，等效实现了"指挥电脑上的 app"。
> 模式 A 可作为后续优化（省去额外进程），两种模式对手机 App 完全透明。

---

## 3. 与 opencode 的对接协议

基于官方 server 文档（https://opencode.ai/docs/server），关键端点：

| 用途 | 方法 | 路径 | 说明 |
|------|------|------|------|
| 健康检查 | GET | `/global/health` | 连接测试 + 版本 |
| 鉴权 | - | - | HTTP Basic Auth（用户名 `opencode`，密码 `OPENCODE_SERVER_PASSWORD`） |
| 会话列表 | GET | `/session` | 获取所有会话 |
| 会话详情 | GET | `/session/:id` | 元数据、状态 |
| 发送消息 | POST | `/session/:id/message` | 同步等待响应 |
| 异步发送 | POST | `/session/:id/prompt_async` | 发完即返回，结果走 SSE |
| 消息列表 | GET | `/session/:id/message` | 历史消息（含 parts） |
| 中止任务 | POST | `/session/:id/abort` | 停止正在运行的任务 |
| 权限响应 | POST | `/session/:id/permissions/:permissionID` | body: `{response: "once"\|"always"\|"reject"}` |
| 实时事件 | GET | `/event` | SSE 流（Server-Sent Events） |
| 文件读取 | GET | `/file/content?path=` | （扩展）查看 agent 改的文件 |
| 会话 diff | GET | `/session/:id/diff` | （扩展）查看改动 |

### 3.1 实时事件流（SSE）— 已实测确认（v1.18.18）

SSE 以默认 `message` 事件名推送 `data: {id, type, properties}` JSON。重点事件：

| 事件 | 关键字段 | App 行为 |
|------|----------|----------|
| `message.part.updated` | `properties.part`（含 `messageID`、`id`、`type`；text 为累计全文） | 按 part.id 增量渲染聊天内容 |
| `permission.asked` | `properties.id`（=permissionID）、`properties.permission`（工具名）、`properties.metadata`/`patterns`（请求内容）、`properties.always`（可记住的规则） | 弹出审批卡片 |
| `session.status` | `properties.status.type`: `busy`/`idle`/`error` | 更新运行状态 |
| `session.idle` / `session.error` | `properties.sessionID` | 任务结束/出错，触发消息重新拉取 |
| `session.updated` | `properties.info`（完整会话对象） | 可忽略（轮询兜底） |
| 其余（plugin.added 等） | - | 忽略 |

注意事项（与直觉不同、已踩坑）：

- 权限响应值只有 **`once` / `always` / `reject`**（不是 allow/deny）
- tool part 的 `state` 是**对象** `{status, input, time, output}`，不是字符串
- `message.part.updated` 的 `messageID` 在 **part 对象内部**，不在 properties 顶层
- 事件名是 `permission.asked`（老版本可能是 `permission.ask`，客户端两者都兼容）

### 3.2 鉴权与安全

- 服务端用 `OPENCODE_SERVER_PASSWORD` 启用 Basic Auth（用户名固定 `opencode`）
- App 内将"地址+用户名+密码"存入设备本地安全存储（`expo-secure-store`，钥匙串/Keystore）
- 传输默认走局域网；跨公网必须走 Tailscale/WireGuard VPN，**禁止裸暴露公网**
- 原型为个人单机使用，暂不做证书（TLS）；生产化时建议在 VPN 内自签证书

---

## 4. 功能设计

### 4.1 MVP 功能（原型范围）

1. **连接管理**
   - 输入电脑局域网地址、端口、密码，一键"测试连接"（调 `/global/health`）
   - 连接配置本地保存，下次自动加载
   - 显示当前连接的 opencode 版本
2. **会话列表**
   - 展示电脑上所有会话（标题、状态、时间、消息数）
   - 下拉刷新；点进会话
3. **聊天 / 指挥**
   - 查看会话全部消息（文本、工具调用、文件改动摘要）
   - 输入框下发新指令（走 `prompt_async` + SSE 实时回流）
   - 任务运行中显示"运行中"状态，支持"中止任务"
   - 自动滚屏
4. **权限审批（核心价值点）**
   - agent 需要权限时，手机弹出审批卡片：工具类型 + 请求内容 + 会话来源
   - 三个按钮：**允许一次** / **总是允许** / **拒绝**
   - 审批结果即时回传服务端，任务不中断

### 4.2 后续迭代（非原型范围）

- 推送通知（权限请求 → APNs/FCM，需自建中继，可复用现有手机 push 服务）
- 模型/agent 切换、会话 fork、`/undo` 回滚
- 查看文件 diff、浏览 agent 修改内容
- 语音输入指令
- 多电脑管理（多份连接配置）

---

## 5. 页面与交互设计

```
启动 → [连接页] ──连接成功──▶ [会话列表页] ──点开会话──▶ [聊天页]
                │                                  │
                └─ 测试连接/保存配置                 └─ 下发指令 / 中止
                                                    └─ 权限审批卡片(模态)
```

### 5.1 连接页
- 电脑 IP、端口（默认 4096）、密码输入
- "测试连接"按钮 → 显示版本号 / 失败原因
- 保存后进入主界面

### 5.2 会话列表页
- 顶部：当前连接信息 + 断开按钮
- 列表：会话标题、运行状态圆点（绿=空闲/黄=运行中/红=错误）、时间、消息数
- 底部：新建会话按钮

### 5.3 聊天页
- 消息气泡列表（用户消息 / agent 消息 / 工具调用折叠卡片）
- 顶部：会话标题 + 运行状态 + "中止"按钮
- 底部：输入框 + 发送
- 权限请求到达时：底部弹出审批卡片（不打断阅读），卡片含"允许一次/总是允许/拒绝"

---

## 6. 技术选型

| 层 | 选择 | 理由 |
|----|------|------|
| 移动框架 | **Expo (React Native)** | 当前机器无 Xcode/Flutter；Expo Go 可在真实手机上一键运行原型，Node 24 已具备 |
| 状态/导航 | React 内置 hooks + React Navigation | 原型轻量 |
| 实时流 | `react-native-sse`（EventSource） | RN 无原生 EventSource，此包在 Expo Go 可用 |
| 本地存储 | `expo-secure-store` | 密码存入钥匙串 |
| 网络 | fetch + Basic Auth header | 无需第三方 SDK |
| 桌面侧 | 伴侣脚本（`start-server.sh` 包装 `opencode serve`） | 复用官方 CLI，零改造 |

> 生产化路径：若后续要上架 App Store，可保留 RN 代码，或按团队栈迁移 Flutter/原生，协议层不变。

---

## 7. 原型验收标准

1. 手机与电脑同 Wi-Fi，手机打开 App 输入电脑 IP + 密码，能成功连接并显示版本
2. 能看到电脑上 opencode 的会话列表（独立 serve 实例中的会话）
3. 手机上发一条指令，电脑上任务开始执行，手机实时看到流式输出
4. 任务中触发权限请求（如执行 bash），手机上弹出审批卡片；点"允许"后任务继续
5. 手机可"中止"正在运行的任务
6. 杀 App 重开，连接配置保留，能直接恢复

---

## 8. 开发计划

| 阶段 | 内容 | 状态 |
|------|------|------|
| M1 设计 | 本文档 | ✅ 完成 |
| M2 原型 | Expo 脚手架 + API 客户端 + 三页面 + 权限审批 | ✅ 完成 |
| M3 联调 | 电脑侧伴侣服务、SSE/权限/中止全接口实测（v1.18.18） | ✅ 完成 |
| M4 收尾 | 真机联调、使用说明、演示 | 进行中 |

---

## 9. 风险与开放问题

| 项 | 风险 | 应对 |
|----|------|------|
| ~~桌面版能否局域网直连~~ | ~~桌面版 server 可能仅绑定 127.0.0.1~~ | ✅ 实测：CLI `serve` 与桌面版共享同一数据库（`~/.local/share/opencode/opencode.db`），会话、模型凭据（deepseek 等）完全互通 |
| 权限事件名变动 | opencode 版本升级可能调整 SSE 事件结构 | 客户端已做容错（`permission.asked`/`permission.ask` 双兼容）+ 版本检测 |
| iOS 后台保活 | 长连接在后台会被系统杀掉，收不到实时审批 | 原型接受前台使用；生产化接 APNs/FCM 推送 |
| CORS | RN 原生 fetch/EventSource 不受浏览器 CORS 限制 | Expo Go（原生宿主）无此问题；仅 Expo Web 场景需 `--cors` |
| 密码管理 | 密码明文存于 `~/.config/opencode-remote/password`（0600） | 个人单机可接受；生产化改用钥匙串+设备配对 |

---

## 10. 目录结构

```
opencode-phone-prototype/
├── DESIGN.md                 # 本文档
├── companion/
│   └── start-server.sh       # 电脑侧伴侣服务脚本
└── app/                      # Expo App
    ├── App.tsx               # 根导航
    ├── src/
    │   ├── api/client.ts     # HTTP + SSE 客户端
    │   ├── api/events.ts     # SSE 事件解析
    │   ├── screens/          # 连接/会话列表/聊天
    │   ├── components/       # 审批卡片、消息气泡等
    │   └── store/            # 配置持久化
    └── app.json
```
