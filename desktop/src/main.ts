import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

// ---------- 状态 ----------
let st: Record<string, boolean | string> = {
  paired: false,
  pending: false,
  loggedIn: false,
  agentRunning: false,
  agentModel: "",
};

function setChip(el: HTMLElement, text: string, kind: "green" | "gray" | "orange" | "red") {
  el.textContent = text;
  el.className = `chip ${kind}`;
}

function refreshStatus() {
  setChip(
    $("st-account"),
    st.loggedIn ? "账号 已登录" : "账号 未登录",
    st.loggedIn ? "green" : "gray",
  );
  setChip(
    $("st-device"),
    st.paired ? "设备 已配对" : st.pending ? "设备 待配对" : st.loggedIn ? "设备 未绑定" : "设备 未登录",
    st.paired ? "green" : st.pending ? "orange" : "gray",
  );
  setChip(
    $("st-agent"),
    st.agentRunning ? `Agent 运行中 (${st.agentModel || ""})` : "Agent 已停止",
    st.agentRunning ? "green" : "gray",
  );
  const btn = $("btn-device-register") as HTMLButtonElement;
  btn.disabled = !st.loggedIn;
  $("btn-device-unbind").classList.toggle("hidden", !st.paired && !st.pending);
  $("pairing-box").classList.toggle("hidden", !st.pending);
  $("device-status").textContent = !st.loggedIn
    ? "未登录"
    : st.paired
      ? "✅ 已配对，等待手机连接"
      : st.pending
        ? "⏳ 等待手机确认配对…"
        : "已登录，尚未绑定设备";
  const startBtn = $("btn-agent-start") as HTMLButtonElement;
  startBtn.disabled = !!st.agentRunning;
  startBtn.textContent = st.agentRunning ? "Agent 运行中…" : "启动 Agent";
  const stopBtn = $("btn-agent-stop") as HTMLButtonElement;
  stopBtn.disabled = !st.agentRunning;
}

// ---------- 活动（与手机端一致的聊天视图） ----------
interface APart { id: string; type: string; text: string; tool?: string; state?: string; }
interface AMsg { id: string; role: string; sessionID: string; parts: APart[]; }
let msgs: AMsg[] = [];

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function partState(p: any): string {
  const st = p.state;
  return typeof st === "string" ? st : st?.status || "";
}
function upsertMsg(id: string, role: string, sessionID: string) {
  let m = msgs.find((x) => x.id === id);
  if (!m) {
    m = { id, role, sessionID, parts: [] };
    msgs.push(m);
  }
  else if (m.role !== role) m.role = role;
  return m;
}
function upsertPart(m: AMsg, p: APart) {
  const i = m.parts.findIndex((x) => x.id === p.id);
  if (i >= 0) m.parts[i] = p; else m.parts.push(p);
}

function onAgentEvent(ev: any) {
  const props = ev.properties || {};
  switch (ev.type) {
    case "message.created":
    case "message.updated": {
      const info = props.info;
      if (info && info.id) upsertMsg(info.id, info.role || "assistant", props.sessionID || "");
      break;
    }
    case "message.part.updated": {
      const p = props.part || {};
      const mid = p.messageID;
      if (!mid) break;
      const m = upsertMsg(mid, "assistant", props.sessionID || "");
      upsertPart(m, {
        id: p.id || Math.random().toString(36).slice(2),
        type: p.type || "text",
        text: p.text || "",
        tool: p.tool,
        state: partState(p),
      });
      break;
    }
    default:
      break;
  }
  renderActivity();
}

function renderActivity() {
  const view = $("activity-view");
  if (msgs.length === 0) { view.innerHTML = '<div class="dim">等待任务…</div>'; return; }
  // 回合级合并：全部消息的思考/工具各汇总为一条（与手机端一致）
  const allReason: APart[] = [];
  const allTools: APart[] = [];
  for (const m of msgs) {
    allReason.push(...m.parts.filter((p) => p.type === "reasoning" && p.text));
    allTools.push(...m.parts.filter((p) => p.type === "tool"));
  }
  let html = "";
  if (allReason.length)
    html += '<span class="act-chip" id="chip-reason">💭 已思考</span> ';
  if (allTools.length)
    html += '<span class="act-chip" id="chip-tools">🛠 工具 ' + allTools.length + '</span>';
  if (html) html = '<div class="act-chips">' + html + "</div>";
  // 只显示最近一个会话（新会话开始时自动切换，不再混流）
  const active = msgs.length ? msgs[msgs.length - 1].sessionID : "";
  let lastShown = "";
  for (const m of msgs) {
    if (m.sessionID !== active) continue;
    const isUser = m.role === "user";
    const textParts = m.parts.filter((p) => p.type === "text" && p.text);
    // 只渲染含正文的消息；纯工具/思考消息不占行（详情在顶部折叠条）
    if (!textParts.length) continue;
    if (lastShown !== m.sessionID) {
      html += '<div class="act-session">── 会话 ' + m.sessionID.slice(4, 12) + " ──</div>";
      lastShown = m.sessionID;
    }
    html += '<div class="act-row ' + (isUser ? "right" : "left") + '">';
    html += '<div class="act-bubble ' + (isUser ? "user" : "agent") + '">';
    html += textParts.map((p) => '<div class="act-text">' + esc(p.text) + "</div>").join("");
    html += "</div></div>";
  }
  view.innerHTML = html;
  const r = document.getElementById("chip-reason");
  const t = document.getElementById("chip-tools");
  if (r) r.onclick = () => openOverlay("reasoning", allReason);
  if (t) t.onclick = () => openOverlay("tools", allTools);
  view.scrollTop = view.scrollHeight;
}

function openOverlay(kind: "reasoning" | "tools", parts: APart[]) {
  let ov = document.getElementById("act-overlay");
  if (!ov) {
    ov = document.createElement("div");
    ov.id = "act-overlay";
    document.body.appendChild(ov);
    ov.addEventListener("click", closeOverlay);
  }
  const inner = parts.map((p) => {
    if (kind === "reasoning") return '<div class="ov-block">' + esc(p.text) + "</div>";
    let body = esc(p.tool || "tool") + " (" + esc(p.state || "") + ")";
    const inp = p.text;
    if (inp) body += "<br/>" + esc(inp);
    return '<div class="ov-block">' + body + "</div>";
  }).join("");
  ov.innerHTML =
    '<div class="ov-panel" id="ov-panel">' +
    '<div class="ov-head">' + (kind === "reasoning" ? "💭 思考过程" : "🛠 工具执行") +
    ' <button id="ov-close">✕</button></div>' +
    '<div class="ov-body">' + inner + "</div></div>";
  const panel = document.getElementById("ov-panel")!;
  panel.addEventListener("click", (e) => e.stopPropagation());
  document.getElementById("ov-close")!.addEventListener("click", closeOverlay);
}

function closeOverlay() {
  const ov = document.getElementById("act-overlay");
  if (ov) ov.remove();
}

listen("agent-event", (e) => onAgentEvent(e.payload));

// ---------- 日志 ----------
function logLine(line: string) {
  const view = $("log-view");
  view.textContent += `${new Date().toLocaleTimeString()}  ${line}\n`;
  view.scrollTop = view.scrollHeight;
}

// ---------- 页签 ----------
async function loginHandler() {
  try {
    const user = await invoke("account_login", {
      relayUrl: DEFAULT_RELAY,
      email: ($("in-email") as HTMLInputElement).value,
      password: ($("in-pass") as HTMLInputElement).value,
    });
    st.loggedIn = true;
    $("account-msg").textContent = `✅ 已登录 ${(user as any).email}`;
    refreshStatus();
  } catch (e) {
    $("account-msg").textContent = `❌ ${e}`;
  }
}

async function registerHandler() {
  try {
    const user = await invoke("account_register", {
      relayUrl: DEFAULT_RELAY,
      email: ($("in-email") as HTMLInputElement).value,
      password: ($("in-pass") as HTMLInputElement).value,
    });
    st.loggedIn = true;
    $("account-msg").textContent = `✅ 已注册并登录 ${(user as any).email}`;
    refreshStatus();
  } catch (e) {
    $("account-msg").textContent = `❌ ${e}`;
  }
}

async function deviceRegisterHandler() {
  try {
    const r = (await invoke("device_register")) as { pairingCode: string; expiresIn: number };
    st.pending = true;
    $("pairing-code").textContent = r.pairingCode.split("").join(" ");
    $("device-msg").textContent = `配对码 ${r.expiresIn} 秒内有效，请在手机 App 中输入`;
    refreshStatus();
  } catch (e) {
    $("device-msg").textContent = `❌ ${e}`;
  }
}

async function deviceUnbindHandler() {
  await invoke("device_unbind");
  refreshStatus();
}

const DEFAULT_RELAY = "https://relay.zhileai.net";

// ---------- 设置弹窗 ----------
function openSettings() {
  const content = $("settings-content");
  content.innerHTML =
    $("pane-device").innerHTML + "<hr/>" + $("pane-agent").innerHTML;
  $("settings-overlay").classList.remove("hidden");
  $("btn-settings-close").onclick = closeSettings;
  $("btn-login").onclick = loginHandler;
  $("btn-register").onclick = registerHandler;
  $("btn-device-register").onclick = deviceRegisterHandler;
  $("btn-device-unbind").onclick = deviceUnbindHandler;
  $("btn-agent-start").onclick = agentStartHandler;
  $("btn-agent-stop").onclick = agentStopHandler;
  refreshStatus();
}
function closeSettings() {
  $("settings-overlay").classList.add("hidden");
}
$("btn-settings").onclick = openSettings;

function currentAgentMode(): string {
  const m = document.querySelector('input[name="agent-mode"]:checked') as HTMLInputElement;
  return m ? m.value : "mini";
}

for (const r of document.querySelectorAll('input[name="agent-mode"]')) {
  (r as HTMLInputElement).onchange = () => {
    const mode = currentAgentMode();
    $("cfg-mini").classList.toggle("hidden", mode !== "mini");
    $("cfg-opencode").classList.toggle("hidden", mode !== "opencode");
  };
}

async function agentStartHandler() {
  const mode = currentAgentMode();
  const apiBase = ($("in-api-base") as HTMLInputElement).value.trim();
  const apiKey = ($("in-api-key") as HTMLInputElement).value.trim();
  const model = ($("in-model") as HTMLInputElement).value.trim();
  const dir = ($("in-agent-dir") as HTMLInputElement).value.trim();
  const permission = ($("in-permission") as HTMLInputElement).value.trim() || null;
  const opencodeModel = ($("in-opencode-model") as HTMLInputElement).value.trim();
  if (mode === "mini" && !apiKey) {
    $("agent-msg").textContent = "❌ 请先填写 API Key";
    $("agent-msg").style.color = "#cf222e";
    return;
  }
  if (mode === "opencode" && !dir) {
    $("agent-msg").textContent = "❌ 请填写工作目录";
    $("agent-msg").style.color = "#cf222e";
    return;
  }
  try {
    $("agent-msg").textContent = "⏳ 正在启动…";
    const r = (await invoke("agent_start", { mode, apiBase, apiKey, model: mode === "opencode" ? opencodeModel : model, dir, permission })) as { engine: string; model?: string };
    st.agentRunning = true;
    st.agentModel = r.engine === "opencode" ? (opencodeModel || "opencode(默认)") : (r.model || "");
    $("agent-msg").textContent = r.engine === "opencode" ? "✅ opencode 已嵌入并启动（日志已接入）" : `✅ MiniAgent 启动成功 (${r.model})`;
    $("agent-msg").style.color = "#1a7f37";
    refreshStatus();
  } catch (e) {
    $("agent-msg").textContent = `❌ 启动失败: ${e}`;
    $("agent-msg").style.color = "#cf222e";
  }
}


async function agentStopHandler() {
  try {
    await invoke("agent_stop");
    st.agentRunning = false;
    st.agentModel = "";
    $("agent-msg").textContent = "🛑 已停止";
    $("agent-msg").style.color = "#57606a";
    refreshStatus();
  } catch (e) {
    $("agent-msg").textContent = `❌ ${e}`;
  }
}


// ---------- 初始化 ----------
async function init() {
  listen<string>("log", (e) => logLine(e.payload));
  listen("engine-status", (e) => {
    st = { ...st, ...(e.payload as Record<string, boolean | string>) };
    refreshStatus();
  });

  try {
    const settings = (await invoke("settings_get")) as any;
    if (settings.email) ($("in-email") as HTMLInputElement).value = settings.email;
    if (settings.api_base) ($("in-api-base") as HTMLInputElement).value = settings.api_base;
    if (settings.api_key) ($("in-api-key") as HTMLInputElement).value = settings.api_key;
    if (settings.model) ($("in-model") as HTMLInputElement).value = settings.model;
    if (settings.agent_dir) ($("in-agent-dir") as HTMLInputElement).value = settings.agent_dir;
    if (settings.opencode_model) ($("in-opencode-model") as HTMLInputElement).value = settings.opencode_model;
    if (settings.permission) ($("in-permission") as HTMLInputElement).value = settings.permission;
    if (settings.agent_mode) {
      const r = document.querySelector(`input[name="agent-mode"][value="${settings.agent_mode}"]`) as HTMLInputElement;
      if (r) r.checked = true;
      const mode = settings.agent_mode === "opencode" ? "opencode" : "mini";
      $("cfg-mini").classList.toggle("hidden", mode !== "mini");
      $("cfg-opencode").classList.toggle("hidden", mode !== "opencode");
    }
    const s = (await invoke("engine_status")) as typeof st;
    st = { ...st, ...s };
    refreshStatus();
  } catch (e) {
    logLine(`初始化失败: ${e}`);
  }

  try {
    const d = (await invoke("agent_detect")) as { type: string; model: string; configured: boolean };
    $("agent-detect").textContent = d.configured
      ? `✅ 已配置 (model: ${d.model})`
      : `ℹ️ 内置 ${d.type}，填写 API Key 后点「启动 Agent」`;
  } catch (e) {
    $("agent-detect").textContent = `❌ ${e}`;
  }
}

init();
