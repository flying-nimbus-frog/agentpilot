import EventSource from "react-native-sse";
import type {
  BusEvent,
  ConnConfig,
  MessageWithParts,
  Part,
  PermissionAsk,
} from "../types";
import { authHeader, parsePermissionAsk } from "./client";

export interface EventHandlers {
  onPermissionAsk: (p: PermissionAsk) => void;
  onTextPart: (sessionID: string, messageID: string, part: Part) => void;
  onToolPart: (sessionID: string, messageID: string, part: Part) => void;
  onSessionState: (sessionID: string, state: string) => void;
  onMessageUpdate: (sessionID: string, messageID: string) => void;
  onError: (err: string) => void;
}

function dispatch(es: EventSource, handlers: EventHandlers, raw: string) {
  let ev: BusEvent;
  try {
    ev = JSON.parse(raw) as BusEvent;
  } catch {
    return;
  }
  const props = ev.properties ?? {};
  switch (ev.type) {
    case "permission.asked":
    case "permission.ask": {
      const p = parsePermissionAsk(props);
      if (p) handlers.onPermissionAsk(p);
      break;
    }
    case "message.part.updated": {
      const part = props.part as Part | undefined;
      if (!part) break;
      const sid = props.sessionID as string;
      const mid = part.messageID as string;
      if (part.type === "text") handlers.onTextPart(sid, mid, part);
      else if (part.type === "tool") handlers.onToolPart(sid, mid, part);
      break;
    }
    case "message.created":
      handlers.onMessageUpdate(
        props.sessionID as string,
        props.messageID as string,
      );
      break;
    case "session.status": {
      const status = props.status as { type?: string } | undefined;
      const st = status?.type;
      if (st) {
        handlers.onSessionState(
          props.sessionID as string,
          st === "busy" ? "running" : st === "idle" ? "idle" : st === "error" ? "error" : st,
        );
      }
      break;
    }
    case "session.idle":
    case "session.error":
      handlers.onSessionState(
        props.sessionID as string,
        ev.type === "session.idle" ? "idle" : "error",
      );
      break;
    default:
      break;
  }
}

export function openEventStream(
  cfg: ConnConfig,
  handlers: EventHandlers,
): EventSource {
  const url = `${cfg.host.startsWith("http") ? "" : "http://"}${cfg.host}:${cfg.port}/event`;
  const es = new EventSource(url, {
    headers: { Authorization: authHeader(cfg) },
    pollingInterval: 0,
  });

  const onData = (raw?: string) => {
    if (raw) dispatch(es, handlers, raw);
  };

  es.addEventListener("message", (e) => onData(e.data ?? undefined));
  es.addEventListener("error", (e) => {
    if (e.type === "error" || e.type === "timeout") {
      handlers.onError("事件连接断开，正在重连…");
    }
  });
  return es;
}

export function applyPartToMessages(
  messages: MessageWithParts[],
  messageID: string,
  part: Part,
): MessageWithParts[] {
  return messages.map((m) => {
    if (m.info.id !== messageID) return m;
    const parts = m.parts.slice();
    const idx = part.id
      ? parts.findIndex((p) => p.id === part.id)
      : parts.length - 1;
    if (idx >= 0) {
      const prev = parts[idx];
      parts[idx] = { ...prev, ...part };
    } else {
      parts.push(part);
    }
    return { ...m, parts };
  });
}

export function appendAssistantMessage(
  messages: MessageWithParts[],
  messageID: string,
): MessageWithParts[] {
  if (messages.some((m) => m.info.id === messageID)) return messages;
  return [
    ...messages,
    {
      info: {
        id: messageID,
        role: "assistant",
        sessionID: messages[0]?.info.sessionID ?? "",
        time: { created: Date.now() },
      },
      parts: [],
    },
  ];
}
