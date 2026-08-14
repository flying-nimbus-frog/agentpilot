import 'package:shared_preferences/shared_preferences.dart';

class SessionStore {
  static const _kUrl = 'relay_url';
  static const _kToken = 'token';
  static const _kEmail = 'email';

  static Future<Map<String, String>?> load() async {
    final sp = await SharedPreferences.getInstance();
    final url = sp.getString(_kUrl);
    final token = sp.getString(_kToken);
    final email = sp.getString(_kEmail);
    if (url == null || token == null || email == null) return null;
    return {_kUrl: url, _kToken: token, _kEmail: email};
  }

  static Future<void> save(String url, String token, String email) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, url);
    await sp.setString(_kToken, token);
    await sp.setString(_kEmail, email);
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kUrl);
    await sp.remove(_kToken);
    await sp.remove(_kEmail);
  }
}
