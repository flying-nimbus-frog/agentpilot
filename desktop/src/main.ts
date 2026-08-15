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
  setChip($("st-relay"), "中继 --", "gray");
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

// ---------- 日志 ----------
function logLine(line: string) {
  const view = $("log-view");
  view.textContent += `${new Date().toLocaleTimeString()}  ${line}\n`;
  view.scrollTop = view.scrollHeight;
}

// ---------- 页签 ----------
function switchTab(name: "device" | "agent" | "log") {
  for (const t of ["device", "agent", "log"] as const) {
    $(`tab-${t}`).classList.toggle("active", t === name);
    $(`pane-${t}`).classList.toggle("active", t === name);
  }
}
$("tab-device").onclick = () => switchTab("device");
$("tab-agent").onclick = () => switchTab("agent");
$("tab-log").onclick = () => switchTab("log");

// ---------- 动作 ----------
const DEFAULT_RELAY = "https://relay.zhileai.net";

$("btn-login").onclick = async () => {
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
};

$("btn-register").onclick = async () => {
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
};

$("btn-device-register").onclick = async () => {
  try {
    const r = (await invoke("device_register")) as { pairingCode: string; expiresIn: number };
    st.pending = true;
    $("pairing-code").textContent = r.pairingCode.split("").join(" ");
    $("device-msg").textContent = `配对码 ${r.expiresIn} 秒内有效，请在手机 App 中输入`;
    refreshStatus();
  } catch (e) {
    $("device-msg").textContent = `❌ ${e}`;
  }
};

$("btn-device-unbind").onclick = async () => {
  await invoke("device_unbind");
  refreshStatus();
};

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

$("btn-agent-start").onclick = async () => {
  const mode = currentAgentMode();
  const apiBase = ($("in-api-base") as HTMLInputElement).value.trim();
  const apiKey = ($("in-api-key") as HTMLInputElement).value.trim();
  const model = ($("in-model") as HTMLInputElement).value.trim();
  const dir = ($("in-agent-dir") as HTMLInputElement).value.trim();
  const permission = ($("in-permission") as HTMLInputElement).value.trim() || null;
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
    const r = (await invoke("agent_start", { mode, apiBase, apiKey, model, dir, permission })) as { engine: string; model?: string };
    st.agentRunning = true;
    st.agentModel = r.engine === "opencode" ? "opencode" : (r.model || "");
    $("agent-msg").textContent = r.engine === "opencode" ? "✅ opencode 已嵌入并启动（日志已接入）" : `✅ MiniAgent 启动成功 (${r.model})`;
    $("agent-msg").style.color = "#1a7f37";
    refreshStatus();
  } catch (e) {
    $("agent-msg").textContent = `❌ 启动失败: ${e}`;
    $("agent-msg").style.color = "#cf222e";
  }
};

$("btn-agent-stop").onclick = async () => {
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
};

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
