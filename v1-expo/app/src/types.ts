export interface ConnConfig {
  host: string;
  port: string;
  username: string;
  password: string;
}

export interface Session {
  id: string;
  parentID?: string;
  title: string;
  directory: string;
  time: { created: number; updated: number };
  type: "chat" | "auto" | "flow";
  agent?: string;
  model?: string;
  totalTokens?: number;
}

export type PartType =
  | "text"
  | "tool"
  | "reasoning"
  | "step_start"
  | "snapshot"
  | "file"
  | "agent"
  | "config"
  | "patch"
  | "shell"
  | string;

export type ToolState =
  | "pending"
  | "running"
  | "completed"
  | "error"
  | "cancelled";

export interface ToolStateInfo {
  status: ToolState;
  input?: unknown;
  output?: unknown;
  title?: string;
  time?: { start?: number; end?: number };
}

export interface Part {
  id?: string;
  type: PartType;
  text?: string;
  tool?: string;
  state?: ToolState | ToolStateInfo;
  input?: unknown;
  output?: unknown;
  title?: string;
  messageID?: string;
}

export interface Message {
  id: string;
  role: "user" | "assistant";
  sessionID: string;
  time: { created: number; completed?: number };
  model?: string;
  error?: string;
}

export interface MessageWithParts {
  info: Message;
  parts: Part[];
}

export interface PermissionAsk {
  permissionID: string;
  sessionID: string;
  tool: string;
  input: unknown;
  userText?: string;
}

export type SessionState = "running" | "idle" | "error" | "aborted";

export interface SessionStatus {
  [sessionID: string]: SessionState;
}

export interface HealthInfo {
  healthy: boolean;
  version: string;
}

export interface BusEvent {
  type: string;
  properties: Record<string, unknown>;
}
