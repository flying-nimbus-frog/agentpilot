import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/protocol.dart';
import '../api/relay.dart';
import '../push/apns.dart';
import '../store/session_store.dart';
import 'login_screen.dart';
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
    widget.app.fetchPlan();
    _initPush();
    widget.app.events.listen((ev) {
      // 审批/补充信息请求到达：震动 + 提示音（全局，任何页面都生效）
      final t = ev['type'];
      if (t == 'permission.asked' || t == 'permission.ask') {
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.alert);
      }
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

  /// 请求推送权限并注册 APNs token（token 异步到达，监听回调）
  Future<void> _initPush() async {
    try {
      final granted = await Apns.requestPermission();
      if (!granted) return;
      Apns.onToken((token) {
        widget.app.registerPushToken(token);
      });
      // 已就绪的情况（重新打开 App）
      final token = await Apns.getToken();
      if (token != null && token.isNotEmpty) {
        await widget.app.registerPushToken(token);
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    try {
      await widget.app.fetchDevices();
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = '$e');
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
              MaterialPageRoute(builder: (_) => DevicesScreen(app: app)),
              (_) => false,
            );
          },
        ),
      ),
      (_) => false,
    );
  }

  Future<void> _pair(Device d) async {
    final codeCtrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入配对码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请在电脑上运行 companion 的终端里查看 6 位配对码',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, letterSpacing: 8),
              decoration: const InputDecoration(
                hintText: '000000',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, codeCtrl.text.trim()),
            child: const Text('确认配对'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    try {
      await widget.app.pairDevice(code);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('✅ 配对成功')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!widget.app.emailVerified)
              Card(
                color: const Color(0xFFFFF8E1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('⚠️ 邮箱未验证，部分功能可能受限',
                            style: TextStyle(fontSize: 13)),
                      ),
                      TextButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await widget.app.resendVerification();
                            messenger.showSnackBar(const SnackBar(
                                content: Text('验证邮件已发送，请查收')));
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('$e')));
                          }
                        },
                        child: const Text('重新发送'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
            // 套餐状态
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.app.plan == 'pro'
                            ? 'Pro 版 · 设备额度无限'
                            : '免费版 · 设备 ${widget.app.activeDevices}/${widget.app.deviceLimit}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (widget.app.plan != 'pro' &&
                        widget.app.deviceLimit > 0 &&
                        widget.app.activeDevices >= widget.app.deviceLimit)
                      TextButton(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('升级入口即将上线，敬请期待')));
                        },
                        child: const Text('了解升级',
                            style: TextStyle(color: Color(0xFF9A6700))),
                      ),
                  ],
                ),
              ),
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
                    d.isPending
                        ? Icons.link
                        : d.online
                            ? Icons.desktop_mac
                            : Icons.desktop_mac_outlined,
                    color: d.isPending
                        ? Colors.orange
                        : d.online
                            ? Colors.green
                            : Colors.grey,
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    d.isPending
                        ? '待配对 · 点击输入配对码'
                        : d.online
                            ? (d.version != null ? '在线 · v${d.version}' : '在线')
                            : '离线 · 上次 ${_fmt(d.lastSeen)}',
                  ),
                  trailing: d.isPending
                      ? TextButton(
                          onPressed: () => _pair(d),
                          child: const Text('配对', style: TextStyle(color: Colors.orange)),
                        )
                      : d.online
                          ? const Icon(Icons.chevron_right)
                          : const Text('离线',
                              style: TextStyle(color: Colors.grey, fontSize: 12)),
                  enabled: !d.isPending && d.online,
                  onTap: d.isPending
                      ? () => _pair(d)
                      : d.online
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      SessionsScreen(app: widget.app, device: d),
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
