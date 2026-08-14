# OpenCode Remote · 手机遥控原型

在手机上用 App 指挥电脑上的 opencode：看进度、下指令、**审批权限**。零服务端改造，纯客户端。

```
[手机 App (Expo/RN)]  ──HTTP + SSE──▶  [电脑 opencode serve :4096]
                                          │ 共享数据库（与桌面版会话/凭据互通）
                                          ▼
                                     ~/.local/share/opencode/opencode.db
```

## 一、电脑端（只需一次）

```bash
cd companion
./start-server.sh [你的项目目录]
```

脚本会打印手机要填的 **地址 / 端口 / 密码**（密码自动生成，存在 `~/.config/opencode-remote/password`）。

> 前置：`opencode` CLI 在 PATH 中（`bun install -g opencode-ai`）。

## 二、手机端

1. 手机安装 **Expo Go**（App Store / 应用商店搜索）
2. 手机和电脑连**同一个 Wi-Fi**
3. 打开 Expo Go → 输入地址 `exp://<电脑IP>:8081`（或扫码）
4. App 里填写电脑端脚本打印的 地址/端口/密码 → 测试连接 → 连接

## 三、功能

- [x] 连接管理（地址/端口/密码，存钥匙串）
- [x] 会话列表（与桌面版共享，含运行状态）
- [x] 实时聊天（SSE 流式输出）
- [x] **权限审批**（允许一次 / 总是允许 / 拒绝）
- [x] 中止任务、新建会话
- [x] 工具调用卡片（bash 等，含输入输出摘要）

## 四、实测记录（2026-08-14, opencode v1.18.18）

| 项 | 结果 |
|----|------|
| 会话/凭据与桌面版互通 | ✅ 共享 `~/.local/share/opencode/opencode.db`，deepseek 模型可用 |
| 发消息 → 流式回流 | ✅ `prompt_async` + `message.part.updated` |
| 权限审批闭环 | ✅ `permission.asked` 事件 → 响应 `once` → 任务继续 → `completed` |
| 中止任务 | ✅ `POST /session/:id/abort` |
| iOS/Android bundle | ✅ Metro 编译通过 |

## 五、开发

```bash
cd app
npm install
npx expo start --lan   # 手机 Expo Go 扫码
npx tsc --noEmit       # 类型检查
```

## 六、已知限制

- iOS 后台会杀掉长连接 → 收不到实时审批（原型前台使用；生产化接推送）
- 密码明文存电脑 `~/.config/opencode-remote/password`（0600 权限）
- 出门在外需 Tailscale/VPN（勿裸暴露公网）
- 服务监听 `0.0.0.0`，不用时 Ctrl+C 停掉
