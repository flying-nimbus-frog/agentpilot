import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/protocol.dart';
import '../api/relay.dart';
import '../push/apns.dart';
import '../store/session_store.dart';
import 'login_screen.dart';
import 'sessions_screen.dart';

/// 设置面板：账号信息 / 设备管理 / 套餐 / 退出登录 / 删除账号
class SettingsSheet extends StatefulWidget {
  final RelayApp app;
  final String pushState;
  const SettingsSheet({super.key, required this.app, required this.pushState});

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  List<Device> get _devices => widget.app.devices;
  String? _msg;

  Future<void> _refresh() async {
    await widget.app.fetchDevices();
    await widget.app.fetchPlan();
    if (mounted) setState(() {});
  }

  /// 注册本机为设备 → 显示配对码
  Future<void> _registerDevice() async {
    try {
      await widget.app.fetchDevices();
      final r = await _apiRegisterDevice();
      if (r == null) return;
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('绑定新设备'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('在电脑桌面端打开 AgentPilot，在"设备"页注册本机为设备，'
                  '然后在电脑上输入这个配对码：',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              Text(r,
                  style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 8,
                      color: Color(0xFF9A6700))),
              const SizedBox(height: 8),
              const Text('10 分钟内有效', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _msg = '绑定失败: $e');
    }
  }

  /// 电脑端注册接口（与旧设备页一致：POST /api/devices 返回配对码）
  Future<String?> _apiRegisterDevice() async {
    final httpBase = widget.app.relayUrl;
    final res = await http.post(
      Uri.parse('$httpBase/api/devices'),
      headers: {
        'Authorization': 'Bearer ${widget.app.token}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'name': '手机添加的设备'}),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw ApiError('HTTP ${res.statusCode}');
    }
    final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return d['pairingCode'] as String?;
  }

  Future<void> _unbind(Device d) async {
    try {
      // 电脑端解绑：删除设备（离线设备直接删）
      final httpBase = widget.app.relayUrl;
      final res = await http.delete(
        Uri.parse('$httpBase/api/devices/${d.id}'),
        headers: {'Authorization': 'Bearer ${widget.app.token}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 && res.statusCode != 404) {
        throw ApiError('解绑失败 HTTP ${res.statusCode}');
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _msg = '解绑失败: $e');
    }
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
    Navigator.of(context).pop(); // 关闭设置
    final nav = Navigator.of(context);
    await nav.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          savedUrl: widget.app.relayUrl,
          onLoggedIn: (app) async {
            await SessionStore.save(app.relayUrl, app.token, app.email);
            await app.fetchDevices();
            await app.connect();
            if (!nav.mounted) return;
            await nav.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => SessionsScreen(app: app)),
              (_) => false,
            );
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
      Navigator.of(context).pop(); // 关闭设置
      final nav = Navigator.of(context);
      await nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginScreen(savedUrl: null, onLoggedIn: (_) async {})),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _msg = '删除失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('设置',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),

            // 账号信息
            _Section(
              title: '账号',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.app.email,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  widget.app.plan == 'pro'
                      ? 'Pro 版 · 设备额度无限'
                      : '免费版 · 设备 ${widget.app.activeDevices}/${widget.app.deviceLimit}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF57606A)),
                ),
                const SizedBox(height: 4),
                Text(widget.pushState,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF57606A))),
              ]),
            ),

            // 设备管理
            _Section(
              title: '设备',
              child: Column(children: [
                for (final d in _devices)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      d.isPending
                          ? Icons.link
                          : d.online
                              ? Icons.desktop_mac
                              : Icons.desktop_mac_outlined,
                      size: 20,
                      color: d.isPending
                          ? Colors.orange
                          : d.online
                              ? Colors.green
                              : Colors.grey,
                    ),
                    title: Text(d.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      d.isPending
                          ? '待配对'
                          : d.online
                              ? '在线'
                              : '离线',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: !d.isPending && !d.online
                        ? TextButton(
                            onPressed: () => _unbind(d),
                            child: const Text('解绑',
                                style: TextStyle(fontSize: 12, color: Colors.red)),
                          )
                        : null,
                  ),
                if (_devices.isEmpty)
                  const Text('暂无设备',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _registerDevice,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加设备',
                        style: TextStyle(fontSize: 13, color: Color(0xFF1F6FEB))),
                  ),
                ),
              ]),
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
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('退出登录', style: TextStyle(fontSize: 14)),
              trailing: const Icon(Icons.logout, size: 18, color: Colors.grey),
              onTap: _logout,
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('删除账号',
                  style: TextStyle(fontSize: 14, color: Colors.red)),
              trailing:
                  const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              onTap: _deleteAccount,
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF57606A), fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}
