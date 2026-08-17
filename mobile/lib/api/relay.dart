/// 中继服务器客户端：REST（账号）+ WebSocket（实时通道）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import 'protocol.dart';

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

class RelayApp {
  final String relayUrl; // 形如 https://server 或 http://192.168.1.5:8080
  String token;
  String email;
  bool emailVerified = false;
  String plan = 'free';
  int planExpires = 0;
  int deviceLimit = 1;
  int activeDevices = 0;

  late String _httpBase;
  late String _wsBase;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _closed = false;

  final Map<String, Completer<CmdResult>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  final ValueNotifier<bool> wsAlive = ValueNotifier(false);
  final StreamController<void> reconnected = StreamController.broadcast();
  final List<Device> _devices = [];

  RelayApp({required this.relayUrl, required this.token, required this.email}) {
    _httpBase = relayUrl;
    _wsBase = relayUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
  }

  Stream<Map<String, dynamic>> get events => _events.stream;
  List<Device> get devices => List.unmodifiable(_devices);

  bool get connected => _ws != null;

  // ---------- REST ----------

  static Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final res = await http
        .post(Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiError((data is Map && data['detail'] != null)
          ? data['detail'].toString()
          : 'HTTP ${res.statusCode}');
    }
    return data as Map<String, dynamic>;
  }

  static Future<RelayApp> register(
      String relayUrl, String email, String password) async {
    final d = await _post('$relayUrl/api/register',
        {'email': email, 'password': password});
    final app = RelayApp(
        relayUrl: relayUrl, token: d['token'], email: email);
    final u = d['user'];
    if (u is Map && u['emailVerified'] is bool) {
      app.emailVerified = u['emailVerified'] as bool;
    }
    return app;
  }

  static Future<RelayApp> login(
      String relayUrl, String email, String password) async {
    final d = await _post(
        '$relayUrl/api/login', {'email': email, 'password': password});
    final app = RelayApp(
        relayUrl: relayUrl, token: d['token'], email: email);
    final u = d['user'];
    if (u is Map && u['emailVerified'] is bool) {
      app.emailVerified = u['emailVerified'] as bool;
    }
    return app;
  }

  /// 发送密码重置邮件
  static Future<void> forgotPassword(String email) async {
    const relayUrl = defaultRelayUrl;
    await _post('$relayUrl/api/forgot-password', {'email': email});
  }

  /// 注册 APNs 推送 token
  /// Permanently delete this account (password required).
  ///
  /// App Store (5.1.1 v) requires an in-app account deletion flow; the
  /// server revokes all sessions, devices, and push tokens before deleting.
  Future<void> deleteAccount(String password) async {
    final res = await http
        .delete(Uri.parse('$_httpBase/api/account'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'password': password}))
        .timeout(const Duration(seconds: 15));
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiError((data is Map && data['detail'] != null)
          ? data['detail'].toString()
          : 'HTTP ${res.statusCode}');
    }
  }

  Future<void> registerPushToken(String deviceToken) async {
    final res = await http
        .post(Uri.parse('$_httpBase/api/push/register'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'token': deviceToken}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      // 推送注册失败不阻塞主流程
    }
  }

  /// 注销 APNs 推送 token（退出登录）
  Future<void> unregisterPushToken(String deviceToken) async {
    try {
      await http.delete(Uri.parse('$_httpBase/api/push/register'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'token': deviceToken}));
    } catch (_) {}
  }

  /// 拉取当前套餐信息
  Future<void> fetchPlan() async {
    final res = await http
        .get(Uri.parse('$_httpBase/api/plan'), headers: {
      'Authorization': 'Bearer $token',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    plan = d['plan'] as String? ?? 'free';
    planExpires = d['planExpires'] as int? ?? 0;
    deviceLimit = d['deviceLimit'] as int? ?? 1;
    activeDevices = d['activeDevices'] as int? ?? 0;
  }

  /// 重新发送邮箱验证邮件（需登录）
  Future<void> resendVerification() async {
    final res = await http
        .post(Uri.parse('$_httpBase/api/resend-verification'), headers: {
      'Authorization': 'Bearer $token',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ApiError('重发失败 HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (data['message'] != null && (data['message'] as String).contains('already')) {
      throw ApiError('邮箱已验证');
    }
  }

  Future<List<Device>> fetchDevices() async {
    final res = await http.get(Uri.parse('$_httpBase/api/devices'), headers: {
      'Authorization': 'Bearer $token',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw ApiError('获取设备失败 HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    _devices
      ..clear()
      ..addAll((data['devices'] as List)
          .map((d) => Device.fromJson(d as Map<String, dynamic>)));
    return devices;
  }

  /// 手机端确认配对：输入桌面端显示的 6 位配对码（按码匹配，无需指定设备）。
  Future<void> pairDevice(String code) async {
    final res = await http.post(
      Uri.parse('$_httpBase/api/devices/pair'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'code': code}),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) throw ApiError('配对码错误，请检查后重试');
    if (res.statusCode == 410) throw ApiError('配对码已过期，请在电脑端重新注册');
    if (res.statusCode != 200) {
      throw ApiError('配对失败 HTTP ${res.statusCode}');
    }
    await fetchDevices();
  }

  // ---------- WebSocket ----------

  Future<void> connect() async {
    _closed = false;
    await _openWs();
  }

  Future<void> _openWs() async {
    // 先取消旧订阅，避免旧连接的断开回调污染新连接状态
    final oldSub = _sub;
    _sub = null;
    await oldSub?.cancel();
    final uri = Uri.parse('$_wsBase/ws/phone?token=${Uri.encodeQueryComponent(token)}');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    _sub = ws.stream.listen(
      _onMessage,
      onError: (_) => _onWsClosed(ws),
      onDone: () => _onWsClosed(ws),
      cancelOnError: true,
    );
    wsAlive.value = true;
    if (!reconnected.isClosed) reconnected.add(null);
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _safeSend({'type': 'ping'});
    });
  }

  /// 仅当前连接可以更新状态；旧连接的断开事件一律忽略
  void _onWsClosed(WebSocketChannel ws) {
    if (!identical(_ws, ws)) return;
    _onDisconnected();
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'device.list':
          final list = (msg['devices'] as List)
              .map((d) => Device.fromJson(d as Map<String, dynamic>))
              .toList();
          _devices
            ..clear()
            ..addAll(list);
          break;
        case 'device.online':
          final id = msg['deviceID'] as String;
          final online = msg['online'] as bool? ?? false;
          final i = _devices.indexWhere((d) => d.id == id);
          if (i >= 0) {
            _devices[i] = Device(
              id: id,
              name: _devices[i].name,
              online: online,
              version: _devices[i].version,
              lastSeen: _devices[i].lastSeen,
            );
          }
          break;
        case 'cmd.result':
          final id = msg['id'] as String;
          final c = _pending.remove(id);
          c?.complete(CmdResult(
            id: id,
            ok: msg['ok'] as bool? ?? false,
            data: msg['data'],
            error: msg['error'] as String?,
          ));
          break;
        case 'event':
          _events.add((msg['event'] as Map).cast<String, dynamic>());
          break;
        default:
          break;
      }
    } catch (_) {
      // 忽略解析失败的帧
    }
  }

  void _onDisconnected() {
    _ws = null;
    wsAlive.value = false;
    _pingTimer?.cancel();
    _pending.forEach(
        (_, c) => c.complete(const CmdResult(id: '', ok: false, error: '连接断开')));
    _pending.clear();
    if (_closed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      _openWs();
    });
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    await _sub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    await _events.close();
  }

  void _safeSend(Map<String, dynamic> msg) {
    try {
      _ws?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  // ---------- 指令 ----------

  static final Random _rand = Random();
  static int _seq = 0;

  Future<CmdResult> cmd(
    String deviceId,
    String method,
    String path, [
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 300),
  ]) async {
    final id = 'req_${DateTime.now().millisecondsSinceEpoch}_${_seq++}_${_rand.nextInt(9999)}';
    final completer = Completer<CmdResult>();
    _pending[id] = completer;
    _safeSend(CmdRequest(
      id: id,
      deviceId: deviceId,
      method: method,
      path: path,
      body: body,
    ).toJson());
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      return CmdResult(id: id, ok: false, error: '指令超时（设备无响应）');
    }
  }
}
