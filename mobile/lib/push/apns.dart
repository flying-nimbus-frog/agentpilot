import 'package:flutter/services.dart';

/// APNs 推送工具（iOS 原生通道）
class Apns {
  static const _channel = MethodChannel('agentpilot/apns');

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
