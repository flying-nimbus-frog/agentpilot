import EventSource from "react-native-sse";
import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import type { OpenCodeClient } from "../api/client";
import {
  appendAssistantMessage,
  applyPartToMessages,
  openEventStream,
} from "../api/events";
import { MessageBubble } from "../components/MessageBubble";
import { PermissionCard } from "../components/PermissionCard";
import type { MessageWithParts, PermissionAsk, SessionState } from "../types";

export function ChatScreen({
  client,
  sessionID,
  title,
  onBack,
}: {
  client: OpenCodeClient;
  sessionID: string;
  title: string;
  onBack: () => void;
}) {
  const [messages, setMessages] = useState<MessageWithParts[]>([]);
  const [input, setInput] = useState("");
  const [state, setState] = useState<SessionState>("idle");
  const [permission, setPermission] = useState<PermissionAsk | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const esRef = useRef<EventSource | null>(null);
  const scrollRef = useRef<ScrollView>(null);
  const stateRef = useRef(state);
  stateRef.current = state;

  const load = useCallback(async () => {
    try {
      const msgs = await client.getMessages(sessionID);
      setMessages(msgs);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [client, sessionID]);

  useEffect(() => {
    load();
    const es = openEventStream(client.getCfg(), {
      onPermissionAsk: (p) => {
        if (p.sessionID === sessionID) setPermission(p);
      },
      onTextPart: (sid, mid, part) => {
        if (sid !== sessionID) return;
        setMessages((prev) => {
          let next = appendAssistantMessage(prev, mid);
          next = applyPartToMessages(next, mid, part);
          return next;
        });
        setState("running");
      },
      onToolPart: (sid, mid, part) => {
        if (sid !== sessionID) return;
        setMessages((prev) => {
          let next = appendAssistantMessage(prev, mid);
          next = applyPartToMessages(next, mid, part);
          return next;
        });
        setState("running");
      },
      onSessionState: (sid, s) => {
        if (sid !== sessionID) return;
        if (s === "idle") {
          setState("idle");
          load();
        } else if (s === "error") {
          setState("error");
          load();
        }
      },
      onMessageUpdate: (sid) => {
        if (sid === sessionID) load();
      },
      onError: (msg) => setError(msg),
    });
    esRef.current = es;
    return () => {
      es.close();
      esRef.current = null;
    };
  }, [client, sessionID, load]);

  const send = async () => {
    const text = input.trim();
    if (!text || sending || state === "running") return;
    setInput("");
    setSending(true);
    setError(null);
    try {
      await client.sendPrompt(sessionID, text);
      setState("running");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSending(false);
    }
  };

  const abort = async () => {
    try {
      await client.abort(sessionID);
      setState("idle");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const respond = async (response: "once" | "always" | "reject") => {
    if (!permission) return;
    try {
      await client.respondPermission(
        sessionID,
        permission.permissionID,
        response,
      );
      setPermission(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const stateColor =
    state === "running" ? "#e6a23c" : state === "error" ? "#cf222e" : "#2da44e";
  const stateText =
    state === "running" ? "运行中" : state === "error" ? "出错" : "空闲";

  return (
    <KeyboardAvoidingView
      style={styles.flex}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
      keyboardVerticalOffset={Platform.OS === "ios" ? 80 : 0}
    >
      <View style={styles.header}>
        <Pressable onPress={onBack} hitSlop={10}>
          <Text style={styles.back}>‹ 返回</Text>
        </Pressable>
        <View style={styles.headerCenter}>
          <Text style={styles.headerTitle} numberOfLines={1}>
            {title}
          </Text>
          <View style={styles.stateRow}>
            <View style={[styles.stateDot, { backgroundColor: stateColor }]} />
            <Text style={styles.stateText}>{stateText}</Text>
          </View>
        </View>
        {state === "running" ? (
          <Pressable onPress={abort} hitSlop={8}>
            <Text style={styles.abort}>中止</Text>
          </Pressable>
        ) : (
          <View style={{ width: 40 }} />
        )}
      </View>

      {error && <Text style={styles.error}>{error}</Text>}

      {loading ? (
        <View style={styles.center}>
          <ActivityIndicator />
        </View>
      ) : (
        <ScrollView
          ref={scrollRef}
          style={styles.chat}
          contentContainerStyle={styles.chatContent}
          onContentSizeChange={() => scrollRef.current?.scrollToEnd({ animated: true })}
        >
          {messages.map((m) => (
            <MessageBubble key={m.info.id} role={m.info.role} parts={m.parts} />
          ))}
        </ScrollView>
      )}

      <View style={styles.inputBar}>
        <TextInput
          style={styles.input}
          value={input}
          onChangeText={setInput}
          placeholder="给电脑上的 opencode 下指令…"
          placeholderTextColor="#8c959f"
          multiline
          editable={state !== "running"}
        />
        <Pressable
          style={[styles.send, (sending || !input.trim() || state === "running") && styles.sendDisabled]}
          onPress={send}
          disabled={sending || !input.trim() || state === "running"}
        >
          {sending ? <ActivityIndicator color="#fff" /> : <Text style={styles.sendText}>发送</Text>}
        </Pressable>
      </View>

      {permission && (
        <PermissionCard
          permission={permission}
          onRespond={respond}
          onClose={() => setPermission(null)}
        />
      )}
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: "#fff" },
  header: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 12,
    paddingTop: 10,
    paddingBottom: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#d0d7de",
  },
  back: { color: "#1f6feb", fontSize: 15, fontWeight: "600" },
  headerCenter: { flex: 1, alignItems: "center" },
  headerTitle: { fontSize: 15, fontWeight: "700", color: "#1f2328" },
  stateRow: { flexDirection: "row", alignItems: "center", marginTop: 2 },
  stateDot: { width: 8, height: 8, borderRadius: 4, marginRight: 4 },
  stateText: { fontSize: 11, color: "#57606a" },
  abort: { color: "#cf222e", fontSize: 14, fontWeight: "600" },
  error: {
    color: "#cf222e",
    fontSize: 12,
    paddingHorizontal: 14,
    paddingVertical: 6,
    backgroundColor: "#fff1f0",
  },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  chat: { flex: 1 },
  chatContent: { padding: 14, paddingBottom: 20 },
  inputBar: {
    flexDirection: "row",
    alignItems: "flex-end",
    padding: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#d0d7de",
    backgroundColor: "#fff",
  },
  input: {
    flex: 1,
    minHeight: 40,
    maxHeight: 110,
    borderWidth: 1,
    borderColor: "#d0d7de",
    borderRadius: 18,
    paddingHorizontal: 14,
    paddingVertical: 9,
    fontSize: 15,
    color: "#1f2328",
  },
  send: {
    marginLeft: 8,
    borderRadius: 18,
    paddingHorizontal: 18,
    paddingVertical: 10,
    backgroundColor: "#1f6feb",
  },
  sendDisabled: { opacity: 0.4 },
  sendText: { color: "#fff", fontSize: 15, fontWeight: "700" },
});
