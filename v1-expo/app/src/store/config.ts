import * as SecureStore from "expo-secure-store";
import type { ConnConfig } from "../types";

const KEY = "opencode-remote-config";

export async function loadConfig(): Promise<ConnConfig | null> {
  const raw = await SecureStore.getItemAsync(KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ConnConfig;
  } catch {
    return null;
  }
}

export async function saveConfig(cfg: ConnConfig): Promise<void> {
  await SecureStore.setItemAsync(KEY, JSON.stringify(cfg));
}

export async function clearConfig(): Promise<void> {
  await SecureStore.deleteItemAsync(KEY);
}
