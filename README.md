# AgentPilot · 手机遥控电脑上的 AI Agent

> 在手机上指挥电脑上的 AI Agent 干活。账号体系 + 云端中继：装好桌面端和手机端，登录同一个账号，手机就能看到你的电脑、下发任务、审批权限、实时查看进度——任何网络环境可用，不限局域网。

## ✨ 特性

- 📱 **手机端（Flutter）**：登录 → 设备列表 → 会话 → 实时聊天，指令从手机直达电脑
- 🖥️ **桌面端（Tauri）**：账号/设备配对管理、Agent 引擎管理、**全量运行日志**
- 🤖 **多 Agent 引擎**：内置 MiniAgent（直连模型）/ 嵌入 opencode（完整工具能力），驱动层可扩展
- 🔐 **安全**：设备级配对（6 位配对码）、账号隔离、TLS 全链路、登录限流
- 🧠 **思考过程可见**：模型推理内容折叠展示，工具执行详情按需展开
- 🌐 **任何网络**：手机 4G/5G/WiFi 都能连，不需要同一局域网

## 🚀 快速开始

### 方式一：使用托管中继（无需部署，推荐）

项目提供官方中继服务，你只需要**客户端**：

```
1. 电脑：安装桌面端应用 → 注册账号 → 登录
2. 电脑：Agent 页选择引擎（opencode / MiniAgent）→ 启动
3. 电脑：设备页「注册本机为设备」→ 记下 6 位配对码
4. 手机：安装 App → 登录同一账号 → 找到待配对设备 → 输入配对码
5. 完成：手机下发指令，电脑执行，权限在手机上审批
```

> 会话、代码、Agent 数据全部在你的电脑本地，中继只做路由转发，不存储你的业务内容。

### 方式二：自托管中继（Docker 一条命令）

```bash
git clone https://github.com/你的用户名/agentpilot.git && cd agentpilot/relay \
  && echo "RELAY_JWT_SECRET=$(openssl rand -hex 32)" > .env \
  && docker compose up -d --build
```

详见 `relay/README.md`（含 nginx 反代、HTTPS、systemd 部署）。

## 🏗️ 架构

```
手机App ──HTTPS/WSS──▶ 云端中继 relay ◀──WSS── 桌面端（Agent 引擎）
  Flutter              Python/FastAPI        Tauri + opencode/MiniAgent
                          │
                  账号体系 · 设备配对 · 指令路由 · 事件广播 · 状态心跳
```

| 组件 | 目录 | 技术 | 职责 |
|------|------|------|------|
| 中继 | `relay/` | Python + FastAPI + WebSocket | 账号、设备配对、路由、状态 |
| 桌面端 | `desktop/` | Tauri (Rust + Web) | 设备管理、Agent 引擎、日志 |
| 手机端 | `mobile/` | Flutter | 遥控界面、审批 |
| 协议 | `PROTOCOL.md` | WebSocket JSON | 三方通信契约 |

## 🔐 安全设计

- **设备级配对**：电脑生成 6 位配对码，手机输入后绑定——同一账号下设备互不可见
- **账号隔离**：所有数据按 user_id 隔离
- **限流**：注册/登录/配对均有频率限制
- **传输**：全程 TLS（HTTPS/WSS）

## 🧱 技术栈

- 中继：Python 3.12 · FastAPI · WebSocket · SQLite
- 桌面端：Rust · Tauri 2 · tokio · reqwest
- 手机端：Flutter 3 · http · web_socket_channel
- 部署：Docker Compose · nginx · Caddy

## 📂 目录结构

```
agentpilot/
├── relay/       # 云端中继服务器（含 Docker 部署）
├── desktop/     # 桌面端应用（Tauri）
├── mobile/      # 手机端应用（Flutter）
├── docs/        # 架构设计文档
├── PROTOCOL.md  # 三方通信协议
└── v1-expo/     # 早期原型（归档）
```

## 🤝 致谢

- [opencode](https://github.com/anomalyco/opencode) —— 内置 Agent 引擎（进程级嵌入，未改动其源码）

## 📄 License

MIT License，详见 [LICENSE](LICENSE)。
