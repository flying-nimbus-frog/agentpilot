# OpenCode Remote 手机端（Flutter）

登录账号 → 看到你的电脑 → 指挥 opencode 干活，权限在手机上审批。

## 一、安装 Flutter

macOS 推荐 Homebrew：

```bash
brew install --cask flutter
flutter doctor   # 确认 iOS/Android 工具链
```

（其他平台见 https://docs.flutter.dev/get-started/install）

## 二、生成工程并运行

```bash
cd mobile
# 首次：生成 iOS/Android 平台工程（不会覆盖 lib/）
flutter create --org dev.opencode --project-name opencode_remote .
flutter pub get
flutter run      # 选择目标设备（模拟器或真机）
```

真机运行需：iOS 用 Xcode 签名（个人免费账号即可），Android 开 USB 调试；或 `flutter run -d <device>`。

## 三、使用流程

1. 打开 App → 输入中继服务器地址（如 `https://relay.example.com`）→ 注册/登录
2. 设备列表 → 选在线的那台电脑
3. 会话列表 → 点开会话 → 下指令
4. agent 请求权限时底部弹出审批卡片：**总是允许 / 允许一次 / 拒绝**

## 四、结构

```
lib/
├── main.dart                # 入口 + 登录态恢复
├── api/
│   ├── protocol.dart        # 协议模型（与 PROTOCOL.md 对应）
│   └── relay.dart           # REST(账号) + WS(实时) 客户端，指令带超时
├── screens/
│   ├── login_screen.dart    # 登录/注册
│   ├── devices_screen.dart  # 设备列表（在线/离线）
│   ├── sessions_screen.dart # 会话列表 + 运行状态
│   └── chat_screen.dart     # 聊天 + 权限审批
├── widgets/                 # 消息气泡、工具卡片、审批卡片
└── store/session_store.dart # token 持久化（shared_preferences）
```

## 五、依赖

- `http`：REST
- `web_socket_channel`：WS 实时通道（含断线自动重连）
- `shared_preferences`：token 本地存储

## 六、注意

- 服务器必须 HTTPS/WSS（iOS ATS 默认禁明文 HTTP）
- WS 断线自动重连；聊天流式事件只在 App 前台时推送（后台保活/推送为 v2.1）
