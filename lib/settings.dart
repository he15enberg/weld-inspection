// Server URL, remembered between runs.
//
// A cloudflared quick tunnel hands out a new *.trycloudflare.com hostname every
// time it starts, so this gets retyped often. Persisting it at least survives
// app restarts within one tunnel session.

import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  static const _key = 'weldz.server_url';

  static Future<String> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? '';
  }

  static Future<void> save(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, url.trim());
  }
}
