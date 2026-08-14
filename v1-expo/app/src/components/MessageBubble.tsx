import React from "react";
import { StyleSheet, Text, View } from "react-native";
import type { Part, ToolState } from "../types";

const STATE_COLORS: Record<ToolState, string> = {
  pending: "#b0b0b0",
  running: "#e6a23c",
  completed: "#67c23a",
  error: "#f56c6c",
  cancelled: "#b0b0b0",
};

function toolStatus(part: Part): ToolState {
  const st = part.state;
  if (typeof st === "string") return st;
  return st?.status ?? "pending";
}

function toolInput(part: Part): unknown {
  if (typeof part.state === "object" && part.state?.input !== undefined)
    return part.state.input;
  return part.input;
}

function toolOutput(part: Part): unknown {
  if (typeof part.state === "object" && part.state?.output !== undefined)
    return part.state.output;
  return part.output;
}

export function ToolCard({ part }: { part: Part }) {
  const status = toolStatus(part);
  const color = STATE_COLORS[status] ?? "#b0b0b0";
  let body = "";
  const input = toolInput(part);
  const output = toolOutput(part);
  if (input !== undefined) {
    body = JSON.stringify(input, null, 2);
    if (body.length > 600) body = `${body.slice(0, 600)}…`;
  }
  if (status === "completed" && output !== undefined) {
    let out = JSON.stringify(output, null, 2);
    if (out.length > 300) out = `${out.slice(0, 300)}…`;
    body = `${body ? `${body}\n\n` : ""}输出: ${out}`;
  }
  return (
    <View style={[styles.tool, { borderColor: color }]}>
      <View style={styles.toolHeader}>
        <View style={[styles.dot, { backgroundColor: color }]} />
        <Text style={styles.toolName}>{part.tool ?? "tool"}</Text>
        <Text style={[styles.toolState, { color }]}>{status}</Text>
      </View>
      {body.length > 0 && <Text style={styles.toolBody}>{body}</Text>}
    </View>
  );
}

export function MessageBubble({
  role,
  parts,
}: {
  role: "user" | "assistant";
  parts: Part[];
}) {
  return (
    <View style={[styles.row, role === "user" ? styles.rowUser : styles.rowAssistant]}>
      <View
        style={[
          styles.bubble,
          role === "user" ? styles.bubbleUser : styles.bubbleAssistant,
        ]}
      >
        {parts.length === 0 && <Text style={styles.placeholder}>…</Text>}
        {parts.map((p, i) => {
          if (p.type === "tool") {
            return <ToolCard key={p.id ?? i} part={p} />;
          }
          if (p.type === "text" && p.text) {
            return (
              <Text key={p.id ?? i} style={role === "user" ? styles.textUser : styles.textAssistant}>
                {p.text}
              </Text>
            );
          }
          return null;
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { marginVertical: 6, flexDirection: "row" },
  rowUser: { justifyContent: "flex-end" },
  rowAssistant: { justifyContent: "flex-start" },
  bubble: {
    maxWidth: "88%",
    borderRadius: 14,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  bubbleUser: { backgroundColor: "#1f6feb" },
  bubbleAssistant: { backgroundColor: "#f2f3f5" },
  placeholder: { color: "#999", fontSize: 14 },
  textUser: { color: "#fff", fontSize: 15, lineHeight: 22 },
  textAssistant: { color: "#1f2328", fontSize: 15, lineHeight: 22 },
  tool: {
    borderWidth: 1,
    borderRadius: 10,
    padding: 8,
    marginTop: 6,
    backgroundColor: "#ffffff",
  },
  toolHeader: { flexDirection: "row", alignItems: "center" },
  dot: { width: 8, height: 8, borderRadius: 4, marginRight: 6 },
  toolName: { fontSize: 13, fontWeight: "600", color: "#1f2328", flex: 1 },
  toolState: { fontSize: 11, textTransform: "uppercase" },
  toolBody: {
    marginTop: 6,
    fontSize: 12,
    color: "#57606a",
    fontFamily: "monospace",
  },
});
