# AGENTS.md — 本仓库智能体约束

这些规则对所有智能体（AI 编码助手）生效，违反即视为事故。

## 提交与推送

- **禁止主动提交（commit）或推送（push）**。只有用户明确说"提交/推送"后才能执行。
- 提交前必须 `git status` / `git diff` 检查，只提交本次任务相关文件，绝不提交密钥（`.env` 等）。
- 提交信息用中文，风格参考历史提交（如 `feat(mobile): ...`、`fix(relay): ...`）。

## 品牌与 logo（唯一来源，重要）

- **logo 唯一来源：本仓库 `docs/logo/`**，所有图标/宣传图只从这里取，禁止在别处引入或保留其它设计稿。
- App 图标用 `docs/logo/app-icon-no-text.png`（无文字版）；登录页/宣传位可用带字版 `agentpilot_logo.*` 或 `app-icon.png`。
- 修改应用名/品牌时，iOS（`Info.plist`）与 Android（`AndroidManifest.xml`）两套显示名要同步改。

## 手机端构建与安装（iOS）

- 产品名：`灵雀 Lingque`（包名 `net.zhileai.agentpilot`，个人 Team `6UMHQGZ6C6`）。
- 构建：`flutter analyze` 零问题后 `flutter build ios --release`。
- **安装一律用升级式**（`xcrun devicectl device install app`，不卸载），否则登录态（shared_preferences）会丢；禁止自定义 uninstall 后再装。
- 免费开发者证书有效期 7 天，到期需重新签名安装。

## 手机远控要点

- 配对标准方向：电脑出码 → 手机「设备」页点「配对」输码（按设备 ID 配对接口）；「添加设备」（反向出码）是废弃路径，勿引导。
- 聊天发送必须乐观回显（用户消息本地先上屏），不得等电脑回推。
- WebSocket 必须带看门狗（22s 无消息自动重连），避免 iOS 后台挂起后指令干等。