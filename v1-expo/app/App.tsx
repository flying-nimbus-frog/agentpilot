import { StatusBar } from "expo-status-bar";
import React, { useEffect, useState } from "react";
import { SafeAreaView, StyleSheet } from "react-native";
import { OpenCodeClient } from "./src/api/client";
import { ChatScreen } from "./src/screens/ChatScreen";
import { ConnectScreen } from "./src/screens/ConnectScreen";
import { SessionsScreen } from "./src/screens/SessionsScreen";
import { loadConfig } from "./src/store/config";
import type { ConnConfig } from "./src/types";

type Route =
  | { name: "connect" }
  | { name: "sessions" }
  | { name: "chat"; sessionID: string; title: string };

export default function App() {
  const [config, setConfig] = useState<ConnConfig | null>(null);
  const [client, setClient] = useState<OpenCodeClient | null>(null);
  const [route, setRoute] = useState<Route>({ name: "connect" });
  const [restoring, setRestoring] = useState(true);

  useEffect(() => {
    loadConfig().then((cfg) => {
      if (cfg) {
        setConfig(cfg);
        setClient(new OpenCodeClient(cfg));
        setRoute({ name: "sessions" });
      }
      setRestoring(false);
    });
  }, []);

  if (restoring) return <SafeAreaView style={styles.flex} />;

  return (
    <SafeAreaView style={styles.flex}>
      <StatusBar style="auto" />
      {route.name === "connect" && (
        <ConnectScreen
          onConnected={(cfg) => {
            setConfig(cfg);
            setClient(new OpenCodeClient(cfg));
            setRoute({ name: "sessions" });
          }}
        />
      )}
      {route.name === "sessions" && client && config && (
        <SessionsScreen
          client={client}
          host={`${config.host}:${config.port}`}
          onOpen={(sessionID, title) => setRoute({ name: "chat", sessionID, title })}
          onDisconnect={() => {
            setClient(null);
            setConfig(null);
            setRoute({ name: "connect" });
          }}
        />
      )}
      {route.name === "chat" && client && (
        <ChatScreen
          client={client}
          sessionID={route.sessionID}
          title={route.title}
          onBack={() => setRoute({ name: "sessions" })}
        />
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: "#fff" },
});
