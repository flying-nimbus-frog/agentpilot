import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import 'chat_screen.dart';

class SessionsScreen extends StatefulWidget {
  final RelayApp app;
  final Device device;
  const SessionsScreen({super.key, required this.app, required this.device});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Session> _sessions = [];
  Map<String, String> _status = {}; // sessionID -> busy/idle/error
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.app.events.listen((ev) {
      final sid = ev['properties'] is Map ? ev['properties']['sessionID'] : null;
      if (ev['type'] == 'session.status' && sid != null) {
        final st = ev['properties']['status'];
        final t = st is Map ? st['type'] as String? : null;
        if (t != null) {
          setState(() => _status[sid] = t == 'busy' ? '运行中' : t == 'idle' ? '空闲' : '出错');
        }
      }
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.app.cmd(widget.device.id, 'GET', '/session');
      if (!r.ok) throw ApiError(r.error ?? '获取会话失败');
      final raw = (r.data as List?) ?? [];
      setState(() {
        _sessions = raw
            .map((e) => Session.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.updated.compareTo(a.updated));
      });
      final st = await widget.app.cmd(widget.device.id, 'GET', '/session/status');
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
    try {
      final r = await widget.app.cmd(
          widget.device.id, 'POST', '/session', {'title': '手机新会话'});
      if (r.ok) {
        final s = Session.fromJson(r.data as Map<String, dynamic>);
        if (!mounted) return;
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => ChatScreen(
                app: widget.app, device: widget.device, session: s, title: s.title)));
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
        title: Text('会话 · ${widget.device.name}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
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
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                                app: widget.app,
                                device: widget.device,
                                session: s,
                                title: s.title),
                          ),
                        ),
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
