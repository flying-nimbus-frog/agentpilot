import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import '../push/apns.dart';
import 'chat_screen.dart';

/// 首页「会话」Tab：会话列表 + 顶部设备切换
class SessionsScreen extends StatefulWidget {
  final RelayApp app;
  const SessionsScreen({super.key, required this.app});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Session> _sessions = [];
  final Map<String, String> _status = {};
  bool _loading = true;
  String? _error;
  Device? _device;
  Timer? _retryTimer;
  bool _loadInFlight = false;
  StreamSubscription<dynamic>? _sub;

  /// 实时从设备列表读在线状态，避免快照停留在"离线"
  Device? get _liveDevice {
    final id = _device?.id;
    if (id == null) return null;
    for (final d in widget.app.devices) {
      if (d.id == id) return d;
    }
    return _device;
  }

  @override
  void initState() {
    super.initState();
    widget.app.fetchPlan();
    _initPush();
    _pickDevice();
    _load();
    _sub = widget.app.events.listen((ev) {
      final t = ev['type'];
      final sid = ev['properties'] is Map ? ev['properties']['sessionID'] : null;
      if (t == 'session.status' && sid != null) {
        final st = ev['properties']['status'];
        final tt = st is Map ? st['type'] as String? : null;
        if (tt != null) {
          setState(() => _status[sid] =
              tt == 'busy' ? '运行中' : tt == 'idle' ? '空闲' : '出错');
        }
      }
      // 设备上线 → 立即刷新会话列表并清掉旧报错
      if (t == 'device.online') {
        final online = ev['online'] == true;
        final did = ev['deviceID'];
        if (did == _device?.id) {
          if (online) {
            if (mounted) setState(() => _error = null);
            _load();
          } else {
            if (mounted) setState(() {});
          }
        }
      }
      // 审批/补充信息请求到达：震动 + 提示音（全局）
      if (t == 'permission.asked' || t == 'permission.ask') {
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.alert);
      }
    });
    // 设备离线/有报错时每 3s 自动重试，恢复正常即停
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final d = _liveDevice;
      if (d == null) return;
      if (_error != null || !d.online) _load();
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
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
        
        return;
      }
      
      Apns.onToken((token) async {
        await widget.app.registerPushToken(token);
        
      });
      final token = await Apns.getToken();
      if (token != null && token.isNotEmpty) {
        await widget.app.registerPushToken(token);
        
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    try {
      if (_device == null) {
        _pickDevice();
        if (_device == null) return;
      }
      if (!widget.app.wsAlive.value) {
        await widget.app.connect();
      }
      // 已有数据时后台静默刷新，不闪转圈
      final hadData = _sessions.isNotEmpty;
      setState(() {
        _loading = !hadData;
        _error = null;
      });
      final device = _device!;
      // 会话列表与状态并行拉取，一次性渲染
      final results = await Future.wait([
        widget.app.cmd(device.id, 'GET', '/session'),
        widget.app.cmd(device.id, 'GET', '/session/status'),
      ]);
      final r = results[0];
      if (!r.ok) throw ApiError(r.error ?? '获取会话失败');
      final raw = (r.data as List?) ?? [];
      final sessions = raw
          .map((e) => Session.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updated.compareTo(a.updated));
      final st = results[1];
      if (st.ok && st.data is Map) {
        final m = st.data as Map<String, dynamic>;
        final statusTmp = <String, String>{};
        m.forEach((k, v) {
          final t = (v is Map) ? v['type'] as String? : null;
          statusTmp[k] = t == 'busy' ? '运行中' : t == 'idle' ? '空闲' : '出错';
        });
        statusTmp.forEach((k, v) => _status[k] = v);
      }
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    } finally {
      _loadInFlight = false;
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
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
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
                  if (_liveDevice != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(children: [
                        const Icon(Icons.desktop_mac,
                            size: 14, color: Color(0xFF57606A)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _liveDevice!.online
                                ? '${_liveDevice!.name} · 在线'
                                : _liveDevice!.name,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF57606A)),
                          ),
                        ),
                        if (_liveDevice!.online)
                          const Icon(Icons.check_circle,
                              size: 13, color: Colors.green),
                        if (widget.app.plan == 'pro')
                          const Text('Pro',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF1A7F37),
                                  fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  if (_error != null &&
                      _liveDevice != null &&
                      _liveDevice!.online)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ),
                  if (_sessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: Center(
                        child: Text(
                          (_liveDevice != null && !_liveDevice!.online)
                              ? '等待设备上线…'
                              : '暂无会话，点右下角新建',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
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
