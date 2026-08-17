import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import '../push/apns.dart';
import 'chat_screen.dart';
import 'settings_sheet.dart';

/// 首页：会话列表 + 顶部设备切换 + 设置入口
class SessionsScreen extends StatefulWidget {
  final RelayApp app;
  const SessionsScreen({super.key, required this.app});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Session> _sessions = [];
  Map<String, String> _status = {};
  bool _loading = true;
  String? _error;
  Device? _device;
  String _pushState = '';
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    widget.app.fetchPlan();
    _initPush();
    _pickDevice();
    _sub = widget.app.events.listen((ev) {
      final sid = ev['properties'] is Map ? ev['properties']['sessionID'] : null;
      if (ev['type'] == 'session.status' && sid != null) {
        final st = ev['properties']['status'];
        final t = st is Map ? st['type'] as String? : null;
        if (t != null) {
          setState(
              () => _status[sid] = t == 'busy' ? '运行中' : t == 'idle' ? '空闲' : '出错');
        }
      }
      // 审批/补充信息请求到达：震动 + 提示音（全局）
      final t = ev['type'];
      if (t == 'permission.asked' || t == 'permission.ask') {
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.alert);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _pickDevice() {
    final devices = widget.app.devices;
    final online = devices.where((d) => d.online).toList();
    _device = (online.isNotEmpty ? online.first : devices.isNotEmpty ? devices.first : null);
  }

  /// 请求推送权限并注册 APNs token
  Future<void> _initPush() async {
    try {
      final granted = await Apns.requestPermission();
      if (!granted) {
        setState(() => _pushState = '⚠️ 推送未授权');
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

  Future<void> _load() async {
    if (_device == null) {
      _pickDevice();
      if (_device == null) return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.app.cmd(_device!.id, 'GET', '/session');
      if (!r.ok) throw ApiError(r.error ?? '获取会话失败');
      final raw = (r.data as List?) ?? [];
      setState(() {
        _sessions = raw
            .map((e) => Session.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.updated.compareTo(a.updated));
      });
      final st = await widget.app.cmd(_device!.id, 'GET', '/session/status');
      if (st.ok && st.data is Map) {
        final m = st.data as Map<String, dynamic>;
        _status = m.map((k, v) {
          final t = (v is Map) ? v['type'] as String? : null;
          return MapEntry(k, t == 'busy' ? '运行中' : t == 'idle' ? '空闲' : '出错');
        });
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newSession() async {
    final device = _device;
    if (device == null) return;
    try {
      final r = await widget.app
          .cmd(device.id, 'POST', '/session', {'title': '手机新会话'});
      if (r.ok) {
        final s = Session.fromJson(r.data as Map<String, dynamic>);
        if (!mounted) return;
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => ChatScreen(
                app: widget.app, device: device, session: s, title: s.title)));
      } else {
        throw ApiError(r.error ?? '新建失败');
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('会话'),
            if (widget.app.devices.length > 1)
              PopupMenuButton<String>(
                tooltip: '切换设备',
                onSelected: (id) {
                  setState(() {
                    _device =
                        widget.app.devices.firstWhere((d) => d.id == id);
                  });
                  _load();
                },
                itemBuilder: (_) => [
                  for (final d in widget.app.devices)
                    PopupMenuItem(
                      value: d.id,
                      child: Row(children: [
                        Icon(d.online ? Icons.desktop_mac : Icons.desktop_mac_outlined,
                            size: 16,
                            color: d.online ? Colors.green : Colors.grey),
                        const SizedBox(width: 8),
                        Text(d.name,
                            style: TextStyle(
                                fontSize: 13, color: d.online ? null : Colors.grey)),
                      ]),
                    ),
                ],
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => SettingsSheet(app: widget.app, pushState: _pushState),
              );
              // 设置页可能改了设备/账号，刷新
              await widget.app.fetchDevices();
              if (mounted) setState(() => _pickDevice());
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_device != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(children: [
                        Icon(Icons.desktop_mac,
                            size: 14,
                            color: _device!.online ? Colors.green : Colors.grey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${_device!.name} · ${_device!.online ? "在线" : "离线"}',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF57606A))),
                        ),
                        if (widget.app.plan == 'pro')
                          const Text('Pro',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF1A7F37),
                                  fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ),
                  if (_sessions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 80),
                      child: Center(
                          child: Text('暂无会话，点右下角新建',
                              style: TextStyle(color: Colors.grey))),
                    ),
                  for (final s in _sessions)
                    Card(
                      child: ListTile(
                        leading: _StatusDot(_status[s.id] ?? '空闲'),
                        title: Text(s.title.isEmpty ? '未命名会话' : s.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s.directory,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(_status[s.id] ?? '',
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        onTap: () async {
                          if (_device == null) return;
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                  app: widget.app,
                                  device: _device!,
                                  session: s,
                                  title: s.title),
                            ),
                          );
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF1F6FEB),
        onPressed: _newSession,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final String status;
  const _StatusDot(this.status);
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      '运行中' => Colors.orange,
      '出错' => Colors.red,
      _ => Colors.green,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
