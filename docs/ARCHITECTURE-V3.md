# OpenCode Remote · 架构设计文档（V3 讨论稿）

> 版本：V3 讨论稿（2026-08-14）
> 目标：先定架构和表结构，讨论通过后再编码

---

## 1. 需求定义

**核心场景**：同一账号下，**多台手机**和**多台电脑**互相配合。手机遥控电脑干活，电脑执行 AI Agent。

**必须支持：**
1. 一个账号可登录多台手机、多台电脑
2. 手机 ↔ 电脑是**多对多**关系，但必须有**显式配对**才建立指挥关系
3. 配对由"电脑端生成配对码 + 手机端输入"完成
4. 配对完成后，双方通过服务端建立**持续通信通道**
5. 通信双方都有**心跳保活**，能感知对方**在线/离线**
6. 设备状态、配对关系都要**落库**（可查询、可管理）

---

## 2. 总体架构（不变）

```
手机App ◀──WSS──▶ 云端中继 ◀──WSS──▶ 电脑端伴侣
                     │
             账号体系 · 设备管理 · 配对管理
             消息路由 · 状态广播 · 心跳
```

中继只做**路由和状态管理**，不执行任务、不存业务数据。

---

## 3. 数据库表设计（核心）

### 3.1 users（账号）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | usr_xxx |
| email | TEXT UNIQUE | 登录名 |
| password_hash / salt | TEXT | pbkdf2 |
| created_at | INTEGER | |

### 3.2 devices（设备 — 手机和电脑都是设备）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | dev_xxx |
| user_id | TEXT FK→users | 归属账号 |
| type | TEXT | **'phone' 或 'computer'** |
| name | TEXT | 显示名（iPhone/小米 / MacBook Air） |
| platform | TEXT | ios / android / macos / windows |
| token | TEXT | 设备令牌（WS 鉴权，长随机串） |
| status | TEXT | pending（待配对）/ active / revoked |
| pairing_code | TEXT | 电脑端待配对时生成的 6 位码 |
| pairing_expires | INTEGER | 配对码过期时间 |
| created_at / last_seen_at | INTEGER | last_seen_at = 最近一次心跳 |

**手机也要注册成设备**——这样"手机在线/离线"才有据可查，手机之间互不混淆。

### 3.3 pairings（配对关系 — 多对多核心表）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | pair_xxx |
| user_id | TEXT FK→users | 冗余方便查询 |
| phone_device_id | TEXT FK→devices | 手机设备 |
| computer_device_id | TEXT FK→devices | 电脑设备 |
| status | TEXT | active / revoked |
| created_at / updated_at | INTEGER | |
| UNIQUE(phone_device_id, computer_device_id) | | 同一对不重复配对 |

**这就是"配对码匹配后建立的联系"**：码匹配成功后，在 pairings 表插入一行，手机↔电脑正式绑定。

### 3.4 ws_sessions（连接会话 — 每次 WS 长连接一条）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| device_id | TEXT FK→devices | 哪个设备 |
| connected_at | INTEGER | |
| last_heartbeat_at | INTEGER | 最近心跳 |
| disconnected_at | INTEGER NULL | 断开时间 |

在线状态 = **实时查内存 hub（权威）+ 落库 last_seen_at（历史/审计）**。

### 3.5 关系图

```
users 1 ──── N devices（type: phone / computer）
devices N ──── M devices（通过 pairings，仅 phone↔computer）
每台设备 1 ──── N ws_sessions（连接记录）
```

---

## 4. 连接与心跳协议

### 4.1 连接

| 设备 | 连接地址 | 鉴权 |
|------|----------|------|
| 手机 | `/ws/phone?token=<手机设备令牌>` | 设备令牌 |
| 电脑 | `/ws/computer?token=<电脑设备令牌>` | 设备令牌 |

（V2 用的是 JWT 登录态；V3 改为**设备令牌**——每个设备注册时分配，登录后自动下发）

### 4.2 心跳

- 客户端每 **25s** 发 `{"type":"ping"}`
- 服务端回 `{"type":"pong"}`，并更新 `ws_sessions.last_heartbeat_at` + `devices.last_seen_at`
- 服务端 **90s** 收不到心跳 → 判离线 → 更新状态 → **广播给所有与之配对的设备**

### 4.3 状态广播

- 设备上线/离线 → 推送给**该账号下与之存在 active pairing 的所有对端设备**
- 手机能看到"哪台电脑在线"；电脑也能看到"哪台手机在线"

---

## 5. 配对流程（多对多版）

```
电脑端：
  login → 注册 computer 设备（status=pending）→ 生成 6 位配对码（10分钟有效）

手机端（任意一台已登录手机）：
  打开 App → "添加电脑" → 输入配对码

服务端：
  校验码 → 创建 pairing(phone_device, computer_device)
  → computer 设备 status=active → 通知电脑端激活
  → 双方建立通信通道

同一电脑可被多台手机配对（家庭共享）；同一手机可配对多台电脑
```

---

## 6. 通信通道（配对建立后）

```
手机 → 中继 → 电脑：
  { "type":"cmd", "targetDevice": "dev_电脑", "cmd":{...} }   # 指令

电脑 → 中继 → 手机：
  { "type":"cmd.result", ... }                                # 结果
  { "type":"event", "event":{...} }                           # agent 事件流

路由规则：以 pairing 为准 —— 手机只能给"与它配对的电脑"发指令
```

**安全边界**：未配对的电脑设备，手机端不可见、不可指挥。

---

## 7. 与 V2 现状的差异（要改的地方）

| 项 | V2 现状 | V3 目标 |
|----|---------|---------|
| 手机是否注册为设备 | ❌ 匿名会话 | ✅ 注册为 phone 设备 |
| 配对粒度 | 账号级（任一手机可指挥所有电脑） | **设备级**（手机↔电脑显式配对） |
| pairings 表 | ❌ 无 | ✅ 新增 |
| devices.type | ❌ 只有电脑 | ✅ phone / computer |
| 电脑感知手机在线 | ❌ | ✅ |
| 路由边界 | 账号内任意 | **限配对关系内** |
| 手机多端 | 天然支持 | 支持且各自有身份 |

**改动范围**：中继（加表/改配对/改路由）、手机 App（加设备注册+添加电脑 UI）、电脑端（配对流程微调）。协议层兼容性按 V3 重写。

---

## 8. 讨论点（已拍板）

| # | 讨论点 | 决策 |
|---|--------|------|
| 1 | 配对粒度 | ✅ **设备级绑定**（手机↔电脑显式配对，未配对不可见不可指挥） |
| 2 | 多台手机 | ✅ **各自独立配对**（每台手机单独与电脑建立 pairing） |
| 3 | 解绑/管理 | ✅ **删电脑设备 → 级联删除其所有配对**；删手机同理；手机端提供绑定列表管理 |
| 4 | 推送 | ✅ **App 后台也要收到电脑上下线提醒**（v3.1 接 APNs/厂商通道；先做前台 WS + 本地通知） |
| 5 | 默认 Agent | ✅ **opencode 内置为默认 Agent**（详见第 9 节） |

## 9. 内置 opencode 为默认 Agent（评估结论：做，采用"按需下载"模式）

### 9.1 三种方案对比

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. 首次运行时自动下载到应用数据目录 | 安装包小；opencode 版本可独立升级；用户零操作 | 首次使用需联网下载 | ✅ **推荐** |
| B. 静态打进安装包 | 开箱即用、可离线 | 包体 +100MB 左右；opencode 升级要发新版；macOS 签名/公证复杂度高 | 作为可选离线包 |
| C. fork 后嵌入代码 | 深度融合 | 维护 fork 成本高；opencode 迭代快，跟版本累 | ❌ 不做 |

### 9.2 方案 A 设计

```
应用内 Agent 管理：
  - 内置"下载器"：首次启动 Agent 时自动检测/下载 opencode
    下载源优先级：国内镜像(npm opencode-ai 的二进制 / ghproxy) → 官方 Releases
  - 下载到 <app_data>/agents/opencode/<version>/ 并校验 sha256
  - 平台/架构匹配：darwin-arm64 / darwin-x64 / linux-x64 / win-x64
  - 版本记录 + 一键"检查更新"

用户侧效果：装好桌面应用 → 点"启动 Agent" → 自动就绪，不需要懂 opencode
```

### 9.3 注意点

- **License 合规**：opencode 为开源项目，内置需随包附 License 声明（下载模式在应用"关于"页注明来源与许可）
- **签名**：方案 A 不修改、不分发二进制，仅下载官方产物，规避 macOS 公证问题
- **架构匹配**：下载前检测本机架构
- **更新策略**：跟随 opencode release，应用内提示升级

---

## 10. 实施顺序

1. 中继：表结构迁移（devices.type + pairings 表）+ 手机设备注册 + 设备级路由（先做，可独立测试）
2. 电脑端：Agent 内置下载器（方案A） + 按新流程适配配对
3. 手机 App：设备注册 + "添加电脑" + 绑定列表 + 上下线通知
4. 全链路回归 + 部署
