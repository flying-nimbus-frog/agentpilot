import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/protocol.dart';
import '../api/relay.dart';

/// 设备 Tab：配对 / 在线状态 / 解绑（微信式底部导航第二页）
class DevicesScreen extends StatefulWidget {
  final RelayApp app;
  const DevicesScreen({super.key, required this.app});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String? _msg;
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    // 设备上下线推送到达时刷新界面
    _sub = widget.app.events.listen((ev) {
      if (ev['type'] == 'device.online') {
        if (mounted) setState(() {});
      }
    });
    widget.app.fetchDevices().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await widget.app.fetchDevices();
    if (mounted) setState(() {});
  }

  /// 手机端确认配对：输入电脑端显示的 6 位配对码
  Future<void> _enterPairCode(Device d) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('配对', textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('设备「${d.name}」等待配对。\n请输入电脑端显示的 6 位配对码：',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                hintText: '000000',
                counterText: '',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) =>
                  Navigator.pop(dialogContext, controller.text.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('确认配对'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      await widget.app.confirmPairDevice(d.id, code);
      if (!mounted) return;
      setState(() => _msg = null);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _msg = '配对失败: $e');
    }
  }

  Future<void> _unbind(Device d) async {
    try {
      final httpBase = widget.app.relayUrl;
      final res = await http
          .delete(Uri.parse('$httpBase/api/devices/${d.id}'),
              headers: {'Authorization': 'Bearer ${widget.app.token}'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 && res.statusCode != 404) {
        throw ApiError('解绑失败 HTTP ${res.statusCode}');
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _msg = '解绑失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.app.devices;
    final active = devices.where((d) => !d.isPending).toList();
    final pending = devices.where((d) => d.isPending).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Text(
                widget.app.plan == 'pro'
                    ? 'Pro 版 · 设备额度无限'
                    : '免费版 · 设备 ${widget.app.activeDevices}/${widget.app.deviceLimit}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF57606A)),
              ),
              const Spacer(),
              Text('在线 ${active.where((d) => d.online).length}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF1F6FEB))),
            ]),
          ),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_msg!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  for (final d in pending)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.link, color: Colors.orange),
                      title: Text(d.name, style: const TextStyle(fontSize: 14)),
                      subtitle: const Text('待配对（输入电脑端显示的配对码）',
                          style: TextStyle(fontSize: 11)),
                      trailing: TextButton(
                        onPressed: () => _enterPairCode(d),
                        child: const Text('配对',
                            style: TextStyle(fontSize: 13, color: Color(0xFF1F6FEB))),
                      ),
                    ),
                  for (final d in active)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        d.online ? Icons.desktop_mac : Icons.desktop_mac_outlined,
                        color: d.online ? Colors.green : Colors.grey,
                      ),
                      title: Text(d.name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                        d.online ? '在线' : '离线',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: !d.online
                          ? TextButton(
                              onPressed: () => _unbind(d),
                              child: const Text('解绑',
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.red)),
                            )
                          : null,
                    ),
                  if (devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 90),
                      child: Center(
                        child: Text('暂无设备，请先在电脑端打开手机面板点「连接」',
                            style: TextStyle(color: Colors.grey, fontSize: 13)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}