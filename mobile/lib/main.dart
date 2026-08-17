import 'package:flutter/material.dart';

import 'api/relay.dart';
import 'screens/sessions_screen.dart';
import 'screens/login_screen.dart';
import 'store/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final saved = await SessionStore.load();
  runApp(OpenCodeRemoteApp(saved: saved));
}

class OpenCodeRemoteApp extends StatelessWidget {
  final Map<String, String>? saved;
  final navigatorKey = GlobalKey<NavigatorState>();
  OpenCodeRemoteApp({super.key, this.saved});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgentPilot',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
        useMaterial3: true,
      ),
      home: saved == null
          ? LoginScreen(savedUrl: null, onLoggedIn: _afterLogin)
          : FutureBuilder(
              future: _restore(saved!),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoginScreen(
                      savedUrl: saved!['relay_url'],
                      onLoggedIn: _afterLogin);
                }
                if (!snapshot.hasData) {
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                }
                return SessionsScreen(app: snapshot.data as RelayApp);
              },
            ),
    );
  }

  Future<RelayApp> _restore(Map<String, String> saved) async {
    final app = RelayApp(
      relayUrl: saved['relay_url']!,
      token: saved['token']!,
      email: saved['email']!,
    );
    await app.fetchDevices();
    await app.connect();
    return app;
  }

  Future<void> _afterLogin(RelayApp app) async {
    await SessionStore.save(app.relayUrl, app.token, app.email);
    await app.fetchDevices();
    await app.connect();
    await navigatorKey.currentState!.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => SessionsScreen(app: app)),
      (_) => false,
    );
  }
}
