import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

// ---------- 状态 ----------
let st = { paired: false, pending: false, loggedIn: false, agentRunning: false };

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
  setChip($("st-agent"), st.agentRunning ? "Agent 运行中" : "Agent 已停止", st.agentRunning ? "green" : "gray");
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
$("btn-login").onclick = async () => {
  try {
    const user = await invoke("account_login", {
      relayUrl: ($("in-relay") as HTMLInputElement).value,
      email: ($("in-email") as HTMLInputElement).value,
      password: ($("in-pass") as HTMLInputElement).value,
    });
    $("account-msg").textContent = `✅ 已登录 ${(user as any).email}`;
    refreshStatus();
  } catch (e) {
    $("account-msg").textContent = `❌ ${e}`;
  }
};

$("btn-register").onclick = async () => {
  try {
    const user = await invoke("account_register", {
      relayUrl: ($("in-relay") as HTMLInputElement).value,
      email: ($("in-email") as HTMLInputElement).value,
      password: ($("in-pass") as HTMLInputElement).value,
    });
    $("account-msg").textContent = `✅ 已注册并登录 ${(user as any).email}`;
    refreshStatus();
  } catch (e) {
    $("account-msg").textContent = `❌ ${e}`;
  }
};

$("btn-device-register").onclick = async () => {
  try {
    const r = (await invoke("device_register")) as { pairingCode: string; expiresIn: number };
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

$("btn-agent-start").onclick = async () => {
  try {
    const r = (await invoke("agent_start", {
      dir: ($("in-agent-dir") as HTMLInputElement).value,
      permission: ($("in-permission") as HTMLInputElement).value || null,
    })) as { version: string | null };
    $("agent-msg").textContent = `✅ Agent 已启动 (opencode ${r.version ?? "?"})`;
    refreshStatus();
  } catch (e) {
    $("agent-msg").textContent = `❌ ${e}`;
  }
};

$("btn-agent-stop").onclick = async () => {
  try {
    await invoke("agent_stop");
    $("agent-msg").textContent = "🛑 Agent 已停止";
    refreshStatus();
  } catch (e) {
    $("agent-msg").textContent = `❌ ${e}`;
  }
};

// ---------- 初始化 ----------
async function init() {
  listen<string>("log", (e) => logLine(e.payload));
  listen("engine-status", (e) => {
    const s = e.payload as typeof st;
    st = { ...st, ...s };
    refreshStatus();
  });

  try {
    const settings = (await invoke("settings_get")) as any;
    if (settings.relay_url) ($("in-relay") as HTMLInputElement).value = settings.relay_url;
    if (settings.email) ($("in-email") as HTMLInputElement).value = settings.email;
    if (settings.agent_dir) ($("in-agent-dir") as HTMLInputElement).value = settings.agent_dir;
    if (settings.permission) ($("in-permission") as HTMLInputElement).value = settings.permission;    const s = (await invoke("engine_status")) as typeof st;
    st = s;
    refreshStatus();
  } catch (e) {
    logLine(`初始化失败: ${e}`);
  }

  try {
    const d = (await invoke("agent_detect")) as { path: string | null; running: boolean };
    $("agent-detect").textContent = d.path
      ? `✅ 已检测到 opencode: ${d.path}`
      : "❌ 未找到 opencode（安装: bun install -g opencode-ai）";
    if (d.path && !($("in-agent-dir") as HTMLInputElement).value) {
      ($("in-agent-dir") as HTMLInputElement).value = ".";
    }
  } catch (e) {
    $("agent-detect").textContent = `❌ ${e}`;
  }
}

init();
