import React, { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from "react-native";
import type { OpenCodeClient } from "../api/client";
import type { Session, SessionStatus } from "../types";

const STATE_COLORS: Record<string, string> = {
  idle: "#2da44e",
  running: "#e6a23c",
  error: "#cf222e",
  aborted: "#8c959f",
};

function fmtTime(ts: number): string {
  const d = new Date(ts);
  const now = Date.now();
  if (now - ts < 60_000) return "刚刚";
  return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function SessionsScreen({
  client,
  host,
  onOpen,
  onDisconnect,
}: {
  client: OpenCodeClient;
  host: string;
  onOpen: (sessionID: string, title: string) => void;
  onDisconnect: () => void;
}) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [statuses, setStatuses] = useState<SessionStatus>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const [s, st] = await Promise.all([
        client.listSessions(),
        client.sessionStatuses(),
      ]);
      setSessions(s);
      setStatuses(st);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [client]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  const createNew = async () => {
    setCreating(true);
    try {
      const s = await client.createSession("手机新会话");
      onOpen(s.id, s.title || "新会话");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setCreating(false);
    }
  };

  return (
    <View style={styles.flex}>
      <View style={styles.header}>
        <View style={styles.headerLeft}>
          <Text style={styles.headerTitle}>会话</Text>
          <Text style={styles.headerHost}>{host}</Text>
        </View>
        <Pressable onPress={onDisconnect} hitSlop={8}>
          <Text style={styles.disconnect}>断开</Text>
        </Pressable>
      </View>

      {error && <Text style={styles.error}>{error}</Text>}

      <FlatList
        data={sessions}
        keyExtractor={(s) => s.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={loading} onRefresh={refresh} />
        }
        ListEmptyComponent={
          <Text style={styles.empty}>
            {loading ? "加载中…" : "暂无会话，点右下角新建"}
          </Text>
        }
        renderItem={({ item }) => {
          const st = statuses[item.id];
          const color = STATE_COLORS[st ?? "idle"] ?? "#2da44e";
          return (
            <Pressable
              style={styles.card}
              onPress={() => onOpen(item.id, item.title || "未命名会话")}
            >
              <View style={styles.cardLeft}>
                <View style={[styles.dot, { backgroundColor: color }]} />
                <View style={styles.cardBody}>
                  <Text style={styles.cardTitle} numberOfLines={1}>
                    {item.title || "未命名会话"}
                  </Text>
                  <Text style={styles.cardMeta} numberOfLines={1}>
                    {item.directory}
                  </Text>
                </View>
              </View>
              <Text style={styles.cardTime}>
                {st ?? ""} · {fmtTime(item.time.updated)}
              </Text>
            </Pressable>
          );
        }}
      />

      <Pressable style={styles.fab} onPress={createNew} disabled={creating}>
        {creating ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.fabText}>＋</Text>
        )}
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: "#fff" },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#d0d7de",
  },
  headerTitle: { fontSize: 20, fontWeight: "800", color: "#1f2328" },
  headerLeft: { flex: 1 },
  headerHost: { fontSize: 12, color: "#8c959f", marginTop: 2 },
  disconnect: { color: "#cf222e", fontSize: 14, fontWeight: "600" },
  error: { color: "#cf222e", fontSize: 13, paddingHorizontal: 16, paddingTop: 8 },
  list: { padding: 12, paddingBottom: 100 },
  empty: { textAlign: "center", marginTop: 60, color: "#8c959f", fontSize: 14 },
  card: {
    backgroundColor: "#f6f8fa",
    borderRadius: 12,
    padding: 12,
    marginBottom: 8,
  },
  cardLeft: { flexDirection: "row", alignItems: "flex-start" },
  dot: { width: 10, height: 10, borderRadius: 5, marginTop: 5, marginRight: 8 },
  cardBody: { flex: 1 },
  cardTitle: { fontSize: 15, fontWeight: "600", color: "#1f2328" },
  cardMeta: { fontSize: 12, color: "#57606a", marginTop: 3 },
  cardTime: {
    marginTop: 8,
    fontSize: 11,
    color: "#8c959f",
    textTransform: "capitalize",
  },
  fab: {
    position: "absolute",
    right: 20,
    bottom: 30,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#1f6feb",
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOpacity: 0.2,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
    elevation: 5,
  },
  fabText: { color: "#fff", fontSize: 28, lineHeight: 32 },
});
