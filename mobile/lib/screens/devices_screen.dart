import 'package:flutter/material.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import 'sessions_screen.dart';

class DevicesScreen extends StatefulWidget {
  final RelayApp app;
  const DevicesScreen({super.key, required this.app});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Device> get _devices => widget.app.devices;
  String? _error;
  String _connState = '连接中…';

  @override
  void initState() {
    super.initState();
    widget.app.events.listen((_) {
      if (mounted) setState(() {});
    });
    _connect();
  }

  Future<void> _connect() async {
    try {
      await widget.app.fetchDevices();
      await widget.app.connect();
      setState(() => _connState = '已连接');
    } catch (e) {
      setState(() {
        _connState = '连接失败';
        _error = '$e';
      });
    }
  }

  Future<void> _refresh() async {
    try {
      await widget.app.fetchDevices();
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的电脑'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Row(children: [
                Icon(widget.app.connected ? Icons.cloud_done : Icons.cloud_off,
                    size: 18,
                    color: widget.app.connected ? Colors.green : Colors.grey),
                const SizedBox(width: 4),
                Text(_connState, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
            if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(
                  child: Text('暂无设备\n\n电脑端运行 companion login 后出现在这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)),
                ),
              ),
            for (final d in _devices)
              Card(
                child: ListTile(
                  leading: Icon(
                    d.online ? Icons.desktop_mac : Icons.desktop_mac_outlined,
                    color: d.online ? Colors.green : Colors.grey,
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    d.online
                        ? (d.version != null ? '在线 · v${d.version}' : '在线')
                        : '离线 · 上次 ${_fmt(d.lastSeen)}',
                  ),
                  trailing: d.online
                      ? const Icon(Icons.chevron_right)
                      : const Text('离线', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  enabled: d.online,
                  onTap: d.online
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SessionsScreen(app: widget.app, device: d),
                            ),
                          )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _fmt(int ts) {
    if (ts == 0) return '未知';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
