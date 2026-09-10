// Where the server is, and the token to reach it.
//
// `defaultUrl` is a permanent Cloudflare named tunnel, so the app works on a
// fresh install with nothing typed in. It is a DEFAULT, not a constant: the
// stored value wins if there is one, so pointing at a laptop or a second
// machine is a five-second edit rather than a rebuild.
//
// Consequence for the flow: the app never prompts on launch or on capture. It
// only asks if `url` comes back empty, which cannot happen while defaultUrl is
// set. Changing it is deliberate -- tap the pill on the live view.

import 'package:shared_preferences/shared_preferences.dart';

class Settings {
  /// Empty on purpose: we are on quick tunnels, whose hostname changes on every
  /// `cloudflared` restart, so a compiled-in value would be wrong more often
  /// than right. The app asks once per tunnel and remembers it until it changes.
  ///
  /// To go back to a permanent URL, put the hostname here and rebuild — a
  /// stored value still wins, so this is only the fallback. A named Cloudflare
  /// tunnel needs a domain on their nameservers; `tailscale funnel 8000` gives
  /// a stable `*.ts.net` hostname without one.
  static const defaultUrl = '';

  /// Shared secret, if the server sets WELDZ_TOKEN. Empty means the server is
  /// open and no header is sent.
  static const defaultToken = '';

  static const _urlKey = 'weldz.server_url';
  static const _tokenKey = 'weldz.token';

  const Settings({required this.url, required this.token});

  final String url;
  final String token;

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_urlKey);
    return Settings(
      // A stored empty string means the user deliberately cleared it, so it is
      // honoured; only a genuinely absent key falls back to the default.
      url: stored ?? defaultUrl,
      token: prefs.getString(_tokenKey) ?? defaultToken,
    );
  }

  static Future<void> save({required String url, required String token}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url.trim());
    await prefs.setString(_tokenKey, token.trim());
  }

  /// Forget the override and go back to [defaultUrl] on next load.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_urlKey);
    await prefs.remove(_tokenKey);
  }

  bool get isSet => url.isNotEmpty;

  /// Short form for the status pill: the host, without scheme or path.
  String get label {
    if (url.isEmpty) return 'tap to set server';
    final u = url.replaceFirst(RegExp(r'^https?://'), '');
    return u.split('/').first;
  }
}
