# OpenCode Remote V2 · 手机遥控电脑上的 opencode

> 账号体系 + 云端中继。手机 App 登录账号 → 看到你的电脑 → 指挥 opencode 干活，权限请求在手机上审批。任何网络环境可用，不限局域网。

## 架构

```
[手机 App (Flutter)] ─HTTPS/WSS─▶ [云端中继 relay (Python/FastAPI)] ◀─WSS── [电脑端伴侣 companion (Python)]
                                      账号体系 · 设备在线 · 指令路由 · 事件广播
                                                                          │
                                                                   opencode serve (本机)
```

## 快速开始

```bash
# 1. 服务器（relay）— 部署到你的云服务器，见 relay/README.md
# 2. 电脑端（companion）
cd companion && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python main.py login --relay wss://你的服务器 --email 你@邮箱 --password 密码
.venv/bin/python main.py run
# 3. 手机端（Flutter）— 见 mobile/README.md，flutter run 后登录同一账号
```

## 目录

| 路径 | 说明 |
|------|------|
| `DESIGN.md` | V2 设计文档 |
| `PROTOCOL.md` | 三方通信协议契约（手机端实现者必读） |
| `relay/` | 云端中继（FastAPI + WS + SQLite 账号体系），含部署文档与自测脚本 |
| `companion/` | 电脑端伴侣守护进程（Python asyncio），含 macOS 开机自启 |
| `mobile/` | 手机端 Flutter App（登录/设备/会话/聊天/权限审批） |
| `v1-expo/` | v1 局域网方案归档（废弃，其 opencode 协议实测经验已复用） |

## 已实测通过（本地全链路）

```
手机模拟 → 登录 → 设备在线 → 会话列表 → 新建会话 → 发消息 → 流式回复 'OK'
        → bash 触发权限请求 → 手机响应 once → 授权生效 → 任务完成
```

## 安全

- 全程 TLS（WSS/HTTPS）；密码 pbkdf2 加盐哈希；JWT 30 天
- `RELAY_JWT_SECRET` 必须自定义，勿用默认值
- 伴侣可配 `permission`（如 `{"bash":"ask"}`），关键操作必须手机审批
- v2.1 规划：端到端加密、设备吊销、推送通知
