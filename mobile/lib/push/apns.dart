import 'package:flutter/services.dart';

/// APNs 推送工具（iOS 原生通道）
class Apns {
  static const _channel = MethodChannel('agentpilot/apns');
  static void Function(String)? _onToken;
  static bool _listening = false;

  /// 注册 token 到达回调（token 是异步到的，务必用这个而不是 getToken 轮询）
  static void onToken(void Function(String token) cb) {
    _onToken = cb;
    if (!_listening) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onToken') {
          final t = call.arguments as String?;
          if (t != null && t.isNotEmpty) _onToken?.call(t);
        }
      });
      _listening = true;
    }
  }

  static Future<bool> requestPermission() async {
    try {
      final r = await _channel.invokeMethod<bool>('register');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> getToken() async {
    try {
      return await _channel.invokeMethod<String>('getToken');
    } catch (_) {
      return null;
    }
  }
}
