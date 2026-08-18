# 桌面端 AgentPilot 安装部署教程

> 目标：让另一台电脑（或另一个 AI 智能体）从源码构建、安装并配置 AgentPilot 桌面端。
> 适用：macOS（Apple Silicon / Intel）

---

## 1. 环境准备

```bash
# Rust 工具链（Tauri 编译必需）
curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh | sh
export PATH="$HOME/.cargo/bin:$PATH"
# 国内 crates 镜像（可选，加速）
mkdir -p ~/.cargo && cat > ~/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = 'rsproxy-sparse'
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
EOF

# Node.js（>=18）+ 包管理器
# Xcode 或 Xcode Command Line Tools（编译 macOS 目标必需）
```

## 2. 克隆与构建

```bash
git clone https://gitee.com/sep20210917/opencode-phone-prototype.git
cd opencode-phone-prototype/desktop
npm install          # 前端依赖（npm 国内源慢可加 --registry=https://registry.npmmirror.com）

# 开发模式运行（调试用，窗口直接弹出）
npm run tauri dev

# 构建安装包（dmg）
npm run tauri build
# 产物: desktop/src-tauri/target/release/bundle/dmg/AgentPilot_0.1.0_aarch64.dmg
```

## 3. 安装到 Applications

```bash
hdiutil attach desktop/src-tauri/target/release/bundle/dmg/*.dmg
cp -R "/Volumes/AgentPilot/AgentPilot.app" /Applications/
hdiutil detach /Volumes/AgentPilot
```

⚠️ 未签名（无 Developer ID）时首次打开：
```bash
xattr -cr /Applications/AgentPilot.app   # 清除隔离标记
open /Applications/AgentPilot.app        # 或右键 → 打开
```

## 4. 首次使用配置（关键）

打开应用后：

### 4.1 登录
- 点右上角 **⚙️ 设置** → 账号区 → 输入邮箱 + 密码 → 登录
- 服务器地址：内置固定 `https://relay.zhileai.net`（无需填写）

### 4.2 绑定设备（生成配对码）
- 设置弹窗 → **注册本机为设备** → 会显示 **6 位配对码**（10 分钟有效）
- 在**手机 App**（同账号登录）设备列表/设置 → 添加设备 → 输入配对码
- 配对成功后顶栏显示：`✅ 设备 已配对`

### 4.3 Agent 引擎配置
- 设置 → Agent 引擎：
  - 引擎类型：**嵌入 opencode**（完整工具能力）
  - **工作目录**：填要工作的项目路径（如 `~/projects/myapp`）
  - **模型**：`deepseek/deepseek-v4-flash`（费用透明，必填）
  - 权限配置（可选）：`{"bash":"ask"}` 让 bash 命令需要手机审批
- 点 **启动 Agent** → 顶栏变绿 `Agent 运行中`

### 4.4 验证
- 手机发消息 → 桌面端活动页实时显示过程
- 日志页可查 opencode 全量日志

## 5. 配置文件位置

| 内容 | 路径 |
|------|------|
| 桌面端配置（登录态/设备令牌/Agent配置） | `~/Library/Application Support/net.zhileai.ocremote/config.json` |
| 运行日志 | `~/Library/Logs/net.zhileai.ocremote/opencode-remote.log` |

⚠️ **config.json 含设备令牌，属敏感数据，切勿提交到仓库或分享。**

## 6. 常见问题

### 6.1 端口 4097 被占（孤儿进程）
应用被杀后，其拉起的 opencode 子进程可能残留：
```bash
lsof -ti :4097 | xargs kill
```
新版已内置启动前自动清理，一般无需手动。

### 6.2 顶栏一直"设备 未绑定"
- 确认设置里已点"注册本机为设备"并完成手机配对
- 配对码 10 分钟过期，过期重新生成

### 6.3 Agent 启动失败 / 30 秒未就绪
- 确认 opencode 已安装：`bun install -g opencode-ai` 或官方脚本
- 确认工作目录存在
- 看日志页具体报错

### 6.4 断线重连
桌面端与中继为长连接，断线自动重连（25s 心跳）。重连失败看日志页。

## 7. 卸载

```bash
rm -rf /Applications/AgentPilot.app
rm -rf "$HOME/Library/Application Support/net.zhileai.ocremote"
rm -rf "$HOME/Library/Logs/net.zhileai.ocremote"
```

---

## 附录：架构速览（给执行者）

```
手机 App ──wss──▶ relay.zhileai.net（中继） ◀──wss── 桌面端（Tauri）
                                                       │
                                                  opencode 引擎（子进程, :4097）
```

- 桌面端 = Tauri（Rust 后端 + Web 前端），界面三部分：活动（实时过程）/ 日志 / ⚙️ 设置
- Agent 引擎支持两种：**opencode**（默认，完整工具）/ **MiniAgent**（直连模型）
- 所有业务数据在用户本机，中继只路由
