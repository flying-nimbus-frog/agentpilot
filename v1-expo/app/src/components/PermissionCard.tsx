import React from "react";
import { Modal, Pressable, StyleSheet, Text, View } from "react-native";
import type { PermissionAsk } from "../types";

export function PermissionCard({
  permission,
  onRespond,
  onClose,
}: {
  permission: PermissionAsk;
  onRespond: (response: "once" | "always" | "reject") => void;
  onClose: () => void;
}) {
  const inputText =
    permission.input !== undefined
      ? JSON.stringify(permission.input, null, 2)
      : "";
  return (
    <Modal transparent visible animationType="slide">
      <View style={styles.overlay}>
        <View style={styles.card}>
          <Text style={styles.title}>⚠️ 需要你的授权</Text>
          <Text style={styles.subtitle}>
            {permission.tool}
            {permission.userText ? ` · ${permission.userText}` : ""}
          </Text>
          {inputText.length > 0 && (
            <View style={styles.bodyWrap}>
              <Text style={styles.body} numberOfLines={12}>
                {inputText.length > 900 ? `${inputText.slice(0, 900)}…` : inputText}
              </Text>
            </View>
          )}
          <Pressable style={[styles.btn, styles.btnAlways]} onPress={() => onRespond("always")}>
            <Text style={styles.btnText}>总是允许</Text>
          </Pressable>
          <Pressable style={[styles.btn, styles.btnOnce]} onPress={() => onRespond("once")}>
            <Text style={styles.btnText}>允许一次</Text>
          </Pressable>
          <Pressable style={[styles.btn, styles.btnDeny]} onPress={() => onRespond("reject")}>
            <Text style={styles.btnText}>拒绝</Text>
          </Pressable>
          <Pressable style={styles.close} onPress={onClose}>
            <Text style={styles.closeText}>稍后处理</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.45)",
    justifyContent: "flex-end",
  },
  card: {
    backgroundColor: "#fff",
    borderTopLeftRadius: 18,
    borderTopRightRadius: 18,
    padding: 20,
    paddingBottom: 36,
  },
  title: { fontSize: 17, fontWeight: "700", color: "#1f2328" },
  subtitle: { marginTop: 4, fontSize: 13, color: "#57606a" },
  bodyWrap: {
    marginTop: 10,
    backgroundColor: "#f6f8fa",
    borderRadius: 10,
    padding: 10,
    maxHeight: 260,
  },
  body: { fontFamily: "monospace", fontSize: 12, color: "#24292f" },
  btn: {
    marginTop: 10,
    borderRadius: 10,
    paddingVertical: 13,
    alignItems: "center",
  },
  btnOnce: { backgroundColor: "#1f6feb" },
  btnAlways: { backgroundColor: "#2da44e" },
  btnDeny: { backgroundColor: "#cf222e" },
  btnText: { color: "#fff", fontSize: 15, fontWeight: "600" },
  close: { marginTop: 12, alignItems: "center" },
  closeText: { color: "#57606a", fontSize: 14 },
});
