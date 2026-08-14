import Constants from "expo-constants";
import React, { useEffect, useState } from "react";
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
import { OpenCodeClient } from "../api/client";
import { loadConfig, saveConfig } from "../store/config";
import type { ConnConfig } from "../types";

function guessHost(): string {
  const uri = Constants.expoConfig?.hostUri;
  if (uri) return uri.split(":")[0];
  return "";
}

export function ConnectScreen({
  onConnected,
}: {
  onConnected: (cfg: ConnConfig) => void;
}) {
  const [host, setHost] = useState("");
  const [port, setPort] = useState("4096");
  const [password, setPassword] = useState("");
  const [username, setUsername] = useState("opencode");
  const [busy, setBusy] = useState(false);
  const [testing, setTesting] = useState(false);
  const [info, setInfo] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadConfig().then((cfg) => {
      if (cfg) {
        setHost(cfg.host);
        setPort(cfg.port);
        setPassword(cfg.password);
        setUsername(cfg.username);
      } else {
        setHost(guessHost());
      }
    });
  }, []);

  const makeCfg = (): ConnConfig => ({
    host: host.trim(),
    port: port.trim(),
    username: username.trim() || "opencode",
    password: password.trim(),
  });

  const test = async () => {
    setTesting(true);
    setError(null);
    setInfo(null);
    try {
      const client = new OpenCodeClient(makeCfg());
      const h = await client.health();
      setInfo(`✅ 连接成功 · opencode v${h.version}`);
    } catch (e) {
      setError(`❌ ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setTesting(false);
    }
  };

  const connect = async () => {
    if (!host || !port || !password) {
      setError("请填写电脑地址、端口和密码");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const cfg = makeCfg();
      await new OpenCodeClient(cfg).health();
      await saveConfig(cfg);
      onConnected(cfg);
    } catch (e) {
      setError(`❌ ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={styles.flex}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <ScrollView contentContainerStyle={styles.wrap} keyboardShouldPersistTaps="handled">
        <Text style={styles.logo}>📱 OpenCode Remote</Text>
        <Text style={styles.tagline}>在手机上指挥电脑上的 opencode</Text>

        <Text style={styles.label}>电脑地址（局域网 IP）</Text>
        <TextInput
          style={styles.input}
          value={host}
          onChangeText={setHost}
          placeholder="如 192.168.1.100"
          autoCapitalize="none"
          autoCorrect={false}
        />
        <Text style={styles.label}>端口</Text>
        <TextInput
          style={styles.input}
          value={port}
          onChangeText={setPort}
          placeholder="4096"
          keyboardType="number-pad"
        />
        <Text style={styles.label}>用户名（默认 opencode）</Text>
        <TextInput
          style={styles.input}
          value={username}
          onChangeText={setUsername}
          autoCapitalize="none"
          autoCorrect={false}
        />
        <Text style={styles.label}>密码（电脑端伴侣服务生成的密码）</Text>
        <TextInput
          style={styles.input}
          value={password}
          onChangeText={setPassword}
          secureTextEntry
          placeholder="启动伴侣服务时会显示"
        />

        {info && <Text style={styles.info}>{info}</Text>}
        {error && <Text style={styles.error}>{error}</Text>}

        <Pressable
          style={[styles.btn, styles.btnGhost]}
          onPress={test}
          disabled={testing || busy}
        >
          {testing ? <ActivityIndicator color="#1f6feb" /> : <Text style={styles.btnGhostText}>测试连接</Text>}
        </Pressable>
        <Pressable
          style={[styles.btn, styles.btnPrimary]}
          onPress={connect}
          disabled={busy || testing}
        >
          {busy ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.btnPrimaryText}>连接</Text>
          )}
        </Pressable>

        <Text style={styles.hint}>
          电脑端需要先运行 companion/start-server.sh 启动伴侣服务
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: "#fff" },
  wrap: { padding: 24, paddingTop: 60 },
  logo: { fontSize: 24, fontWeight: "800", color: "#1f2328" },
  tagline: { marginTop: 4, marginBottom: 28, fontSize: 14, color: "#57606a" },
  label: { marginTop: 14, fontSize: 13, color: "#57606a", fontWeight: "600" },
  input: {
    marginTop: 6,
    borderWidth: 1,
    borderColor: "#d0d7de",
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 11,
    fontSize: 15,
    color: "#1f2328",
  },
  btn: {
    marginTop: 16,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
  },
  btnPrimary: { backgroundColor: "#1f6feb" },
  btnPrimaryText: { color: "#fff", fontSize: 16, fontWeight: "700" },
  btnGhost: { backgroundColor: "#f6f8fa", borderWidth: 1, borderColor: "#d0d7de" },
  btnGhostText: { color: "#1f6feb", fontSize: 15, fontWeight: "600" },
  info: { marginTop: 14, color: "#1a7f37", fontSize: 13 },
  error: { marginTop: 14, color: "#cf222e", fontSize: 13 },
  hint: { marginTop: 24, fontSize: 12, color: "#8c959f", textAlign: "center" },
});
