import type {
  ConnConfig,
  HealthInfo,
  MessageWithParts,
  PermissionAsk,
  Session,
  SessionStatus,
} from "../types";

function b64(s: string): string {
  return btoa(unescape(encodeURIComponent(s)));
}

export function baseUrl(cfg: ConnConfig): string {
  return `http://${cfg.host}:${cfg.port}`;
}

export function authHeader(cfg: ConnConfig): string {
  return `Basic ${b64(`${cfg.username}:${cfg.password}`)}`;
}

export class OpenCodeClient {
  private base: string;
  private cfg: ConnConfig;

  constructor(cfg: ConnConfig) {
    this.cfg = cfg;
    this.base = baseUrl(cfg);
  }

  getCfg(): ConnConfig {
    return this.cfg;
  }

  private async req<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await fetch(`${this.base}${path}`, {
      ...init,
      headers: {
        Authorization: authHeader(this.cfg),
        "Content-Type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`HTTP ${res.status} ${path}: ${body.slice(0, 200)}`);
    }
    if (res.status === 204) return undefined as T;
    return (await res.json()) as T;
  }

  async health(): Promise<HealthInfo> {
    return this.req<HealthInfo>("/global/health");
  }

  async listSessions(): Promise<Session[]> {
    return this.req<Session[]>("/session");
  }

  async createSession(title?: string): Promise<Session> {
    return this.req<Session>("/session", {
      method: "POST",
      body: JSON.stringify({ title }),
    });
  }

  async getMessages(
    sessionID: string,
    limit = 200,
  ): Promise<MessageWithParts[]> {
    return this.req<MessageWithParts[]>(
      `/session/${sessionID}/message?limit=${limit}`,
    );
  }

  async sendPrompt(sessionID: string, text: string): Promise<void> {
    await this.req(`/session/${sessionID}/prompt_async`, {
      method: "POST",
      body: JSON.stringify({ parts: [{ type: "text", text }] }),
    });
  }

  async abort(sessionID: string): Promise<void> {
    await this.req(`/session/${sessionID}/abort`, { method: "POST" });
  }

  async respondPermission(
    sessionID: string,
    permissionID: string,
    response: "once" | "always" | "reject",
  ): Promise<void> {
    await this.req(`/session/${sessionID}/permissions/${permissionID}`, {
      method: "POST",
      body: JSON.stringify({ response }),
    });
  }

  async sessionStatuses(): Promise<SessionStatus> {
    return this.req<SessionStatus>("/session/status");
  }
}

export function parsePermissionAsk(
  props: Record<string, unknown>,
): PermissionAsk | null {
  const sessionID = props.sessionID as string | undefined;
  const permissionID =
    (props.permissionID as string | undefined) ?? (props.id as string | undefined);
  if (!sessionID || !permissionID) return null;
  const tool =
    (props.tool as string) ?? (props.permission as string) ?? "unknown";
  return {
    permissionID,
    sessionID,
    tool,
    input: props.metadata ?? props.patterns ?? props.input,
    userText: props.userText as string | undefined,
  };
}
