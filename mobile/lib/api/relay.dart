/// 中继服务器客户端：REST（账号）+ WebSocket（实时通道）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

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
    return RelayApp(
        relayUrl: relayUrl, token: d['token'], email: email);
  }

  static Future<RelayApp> login(
      String relayUrl, String email, String password) async {
    final d = await _post(
        '$relayUrl/api/login', {'email': email, 'password': password});
    return RelayApp(
        relayUrl: relayUrl, token: d['token'], email: email);
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

  /// 手机端确认配对：输入桌面端显示的 6 位配对码。
  Future<void> pairDevice(String deviceId, String code) async {
    final res = await http.post(
      Uri.parse('$_httpBase/api/devices/$deviceId/pair'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'code': code}),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) throw ApiError('配对码错误，请检查后重试');
    if (res.statusCode == 410) throw ApiError('配对码已过期，请在电脑端重新登录注册');
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
    final uri = Uri.parse('$_wsBase/ws/phone?token=${Uri.encodeQueryComponent(token)}');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    _sub = ws.stream.listen(
      _onMessage,
      onError: (_) => _onDisconnected(),
      onDone: _onDisconnected,
      cancelOnError: true,
    );
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _safeSend({'type': 'ping'});
    });
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
