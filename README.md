# AgentPilot · Control Your AI Agents from Your Phone

> Control the AI coding agents on your computer from your phone. Account system + cloud relay: install the desktop app and the mobile app, log in with the same account, and your phone can see your computers, dispatch tasks, approve permissions, and watch progress in real time — from anywhere, not just your LAN.

## ✨ Features

- 📱 **Mobile app (Flutter)**: Login → device list → sessions → real-time chat; commands go straight from your phone to your computer
- 🖥️ **Desktop app (Tauri)**: Account & device pairing management, agent engine management, **full runtime logs**
- 🤖 **Multiple agent engines**: Built-in MiniAgent (direct LLM) / embedded opencode (full tool capabilities), extensible driver layer
- 🔐 **Security**: Device-level pairing (6-digit code), per-account isolation, TLS end-to-end, rate limiting
- 🧠 **Visible thinking process**: Model reasoning is shown collapsed; tool execution details expand on demand
- 🌐 **Any network**: Works over 4G/5G/WiFi — no LAN requirement

## 🚀 Quick Start

### Option 1: Use the hosted relay (no deployment, recommended)

The project provides an official relay service — you only need the **clients**:

```
1. Computer: Install the desktop app → create an account → log in
2. Computer: Agent tab → pick an engine (opencode / MiniAgent) → start
3. Computer: Device tab → "Register this machine as a device" → note the 6-digit pairing code
4. Phone: Install the app → log in with the same account → tap the pending device → enter the pairing code
5. Done: Dispatch tasks from your phone; permissions are approved on your phone
```

> Sessions, code, and agent data all stay on your computer locally. The relay only routes messages — it never stores your business content.

### Option 2: Self-host the relay (Docker, one command)

```bash
git clone https://github.com/flying-nimbus-frog/agentpilot.git && cd agentpilot/relay \
  && echo "RELAY_JWT_SECRET=$(openssl rand -hex 32)" > .env \
  && docker compose up -d --build
```

See `relay/README.md` for nginx reverse proxy, HTTPS, and systemd deployment.

## 🏗️ Architecture

```
Mobile app ──HTTPS/WSS──▶ Cloud relay ◀──WSS── Desktop app (agent engine)
  Flutter                 Python/FastAPI        Tauri + opencode/MiniAgent
                              │
              Accounts · device pairing · command routing · event broadcast · heartbeats
```

| Component | Directory | Tech | Responsibility |
|-----------|-----------|------|----------------|
| Relay | `relay/` | Python + FastAPI + WebSocket | Accounts, device pairing, routing, presence |
| Desktop | `desktop/` | Tauri (Rust + Web) | Device management, agent engine, logs |
| Mobile | `mobile/` | Flutter | Remote control UI, approvals |
| Protocol | `PROTOCOL.md` | WebSocket JSON | Contract between the three parties |

## 🔐 Security Design

- **Device-level pairing**: The computer generates a 6-digit code; the phone enters it to bind — devices on the same account can't see each other
- **Account isolation**: All data is isolated by `user_id`
- **Rate limiting**: Register / login / pairing all rate-limited
- **Transport**: TLS everywhere (HTTPS/WSS)

## 🧱 Tech Stack

- Relay: Python 3.12 · FastAPI · WebSocket · SQLite
- Desktop: Rust · Tauri 2 · tokio · reqwest
- Mobile: Flutter 3 · http · web_socket_channel
- Deployment: Docker Compose · nginx · Caddy

## 📂 Repository Layout

```
agentpilot/
├── relay/       # Cloud relay server (incl. Docker deployment)
├── desktop/     # Desktop app (Tauri)
├── mobile/      # Mobile app (Flutter)
├── docs/        # Architecture design docs
├── PROTOCOL.md  # Communication protocol
└── v1-expo/     # Early prototype (archived)
```

## 🤝 Acknowledgements

- [opencode](https://github.com/anomalyco/opencode) — embedded agent engine (process-level embedding; its source is untouched)

## 📄 License

MIT License — see [LICENSE](LICENSE).
