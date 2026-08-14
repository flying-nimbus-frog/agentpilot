# OpenCode Remote 电脑端伴侣（companion）

手机遥控的电脑侧守护进程：拉起本地 `opencode serve`，连中继，代理指令 + 转发事件。

## 安装

```bash
cd companion
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

前置：`opencode` 在 PATH 中（`bun install -g opencode-ai` 或官方安装脚本）。

## 使用

### 1. 登录并注册本机设备（一次）

```bash
.venv/bin/python main.py login \
  --relay ws://你的服务器:8000 \
  --email 你的邮箱 \
  --password 你的密码
```

- `--relay` 支持 `ws://` / `wss://`；生产必须 `wss://`
- 自动注册设备并保存令牌到 `~/.config/opencode-remote/companion.json`

### 2. 运行守护进程

```bash
.venv/bin/python main.py run [--dir /你的/项目目录]
```

输出示例：

```
[companion] 启动本地 opencode: /Users/xxx/.bun/bin/opencode serve --hostname 127.0.0.1 --port 4097
[companion] 本地 opencode v1.18.18 就绪 @ :4097
[companion] 已连接中继: ws://server:8000
```

### 3. 开机自启（macOS launchd）

`~/Library/LaunchAgents/com.opencode-remote.companion.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.opencode-remote.companion</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/你的用户名/PycharmProjects/opencode-phone-prototype/companion/.venv/bin/python</string>
    <string>main.py</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/你的用户名/PycharmProjects/opencode-phone-prototype/companion</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/oc-companion.log</string>
  <key>StandardErrorPath</key><string>/tmp/oc-companion.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.opencode-remote.companion.plist
```

## 配置项（companion.json）

| 字段 | 说明 |
|------|------|
| `relay_url` | 中继地址（可被 `run --relay` 覆盖） |
| `directory` | opencode 工作目录（可被 `run --dir` 覆盖） |
| `opencode_port` | 本地 opencode 端口（默认 4097，本机唯一即可） |
| `permission` | 可选：openode 权限覆盖，如 `{"bash":"ask"}` 让 bash 必须手机审批 |

> `permission` 是安全利器：把危险操作设为 `ask`，手机遥控时所有关键动作都在你眼皮底下审批。

## 说明

- 会话/凭据与 opencode 桌面版**共享同一数据库**（`~/.local/share/opencode/opencode.db`），手机看到的会话和桌面版一致
- 断线自动重连（指数退避）；本地 opencode 崩溃不会自动拉起（保持简单，重启 `run` 即可）
