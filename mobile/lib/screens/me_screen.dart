import 'package:flutter/material.dart';

import '../api/relay.dart';
import '../push/apns.dart';
import '../store/session_store.dart';
import 'login_screen.dart';

/// 「我」Tab：账号、套餐、推送、退出登录、删除账号
class MeScreen extends StatefulWidget {
  final RelayApp app;
  const MeScreen({super.key, required this.app});

  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> {
  String _pushState = '';
  String? _msg;

  @override
  void initState() {
    super.initState();
    widget.app.fetchPlan();
    _initPush();
  }

  Future<void> _initPush() async {
    try {
      final granted = await Apns.requestPermission();
      if (!granted) {
        if (mounted) setState(() => _pushState = '推送未授权');
        return;
      }
      setState(() => _pushState = '推送注册中…');
      Apns.onToken((token) async {
        await widget.app.registerPushToken(token);
        if (mounted) setState(() => _pushState = '推送已注册');
      });
      final token = await Apns.getToken();
      if (token != null && token.isNotEmpty) {
        await widget.app.registerPushToken(token);
        if (mounted) setState(() => _pushState = '推送已注册');
      }
    } catch (_) {}
  }

  Future<void> _logout() async {
    try {
      final t = await Apns.getToken();
      if (t != null && t.isNotEmpty) {
        await widget.app.unregisterPushToken(t);
      }
    } catch (_) {}
    await widget.app.close();
    await SessionStore.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          savedUrl: widget.app.relayUrl,
          onLoggedIn: (app) async {
            await SessionStore.save(app.relayUrl, app.token, app.email);
            await app.fetchDevices();
            await app.connect();
          },
        ),
      ),
      (_) => false,
    );
  }

  Future<void> _deleteAccount() async {
    final passwordController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除账号'),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '删除后账号、设备绑定和推送设置将被永久清除，且无法恢复。此操作不可撤销。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '输入密码确认',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    final password = passwordController.text;
    if (confirmed != true || password.isEmpty) return;

    try {
      await widget.app.deleteAccount(password);
      await widget.app.close();
      await SessionStore.clear();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => LoginScreen(savedUrl: null, onLoggedIn: (_) async {})),
        (_) => false,
      );
    } catch (e) {
      if (mounted) setState(() => _msg = '删除失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF1F6FEB),
              child: Text(
                widget.app.email.isEmpty
                    ? '?'
                    : widget.app.email[0].toUpperCase(),
                style: const TextStyle(color: Colors.white),
              ),
            ),
            title: Text(widget.app.email,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              widget.app.plan == 'pro'
                  ? 'Pro 版'
                  : '免费版 · 设备 ${widget.app.activeDevices}/${widget.app.deviceLimit}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF57606A)),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_outlined, size: 20),
            title: const Text('推送通知', style: TextStyle(fontSize: 14)),
            subtitle: Text(_pushState,
                style: const TextStyle(fontSize: 12, color: Color(0xFF57606A))),
            onTap: _initPush,
          ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_msg!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout, size: 20),
            title: const Text('退出登录', style: TextStyle(fontSize: 14)),
            onTap: _logout,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
            title: const Text('删除账号',
                style: TextStyle(fontSize: 14, color: Colors.red)),
            onTap: _deleteAccount,
          ),
        ],
      ),
    );
  }
}