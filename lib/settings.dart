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

  /// Detection threshold. 0.25 is what the model was evaluated at.
  ///
  /// Worth knowing before turning it down: on real phone captures the defect
  /// detections sit at a median confidence of 0.135, and only 9 of 133 reach
  /// 0.25 — so dropping to 0.10 does not uncover hidden defects, it admits
  /// near-random boxes on whatever else is on the bench. Clamped to
  /// [confMin, confMax] here and clamped again on the server.
  static const defaultConf = 0.25;
  static const confMin = 0.01;
  static const confMax = 0.95;

  /// Quarter turn applied before inference, anticlockwise degrees.
  ///
  /// 270 (a quarter turn CLOCKWISE) is what this hardware needs: ARKit hands
  /// over the camera buffer in the sensor's own orientation and nothing
  /// corrects it, so the part arrives on its end — which the model has never
  /// seen. Measured over the stored captures, 270 finds the weld seam in 9 of
  /// 9 frames against 3 of 9 untouched. The direction is not symmetric: 90
  /// also finds the seam but drops workpiece confidence from 0.94 to 0.61.
  static const defaultRotate = 270;

  /// Square crop side, in captured pixels, applied after the turn. 0 disables.
  ///
  /// The model was trained only on square images, and `preprocess` stretches
  /// whatever it gets to a square 1272 — so a 4:3 frame arrives squeezed 25%.
  /// The server snaps this down to a size whose edges land on whole depth
  /// pixels (1392 becomes 1380), because a crop that splits a depth pixel puts
  /// colour and depth out of step and quietly corrupts every millimetre.
  static const defaultCrop = 1380;

  static const _urlKey = 'weldz.server_url';
  static const _tokenKey = 'weldz.token';
  static const _confKey = 'weldz.conf';
  static const _rotateKey = 'weldz.rotate';
  static const _cropKey = 'weldz.crop';

  const Settings({
    required this.url,
    required this.token,
    this.conf = defaultConf,
    this.rotate = defaultRotate,
    this.crop = defaultCrop,
  });

  final String url;
  final String token;
  final double conf;
  final int rotate;
  final int crop;

  static double clampConf(double v) => v.clamp(confMin, confMax);

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_urlKey);
    return Settings(
      // A stored empty string means the user deliberately cleared it, so it is
      // honoured; only a genuinely absent key falls back to the default.
      url: stored ?? defaultUrl,
      token: prefs.getString(_tokenKey) ?? defaultToken,
      conf: clampConf(prefs.getDouble(_confKey) ?? defaultConf),
      rotate: prefs.getInt(_rotateKey) ?? defaultRotate,
      crop: prefs.getInt(_cropKey) ?? defaultCrop,
    );
  }

  static Future<void> save({
    required String url,
    required String token,
    double? conf,
    int? rotate,
    int? crop,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url.trim());
    await prefs.setString(_tokenKey, token.trim());
    if (conf != null) await prefs.setDouble(_confKey, clampConf(conf));
    if (rotate != null) await prefs.setInt(_rotateKey, rotate);
    if (crop != null) await prefs.setInt(_cropKey, crop);
  }

  /// Forget the override and go back to [defaultUrl] on next load.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_urlKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_confKey);
    await prefs.remove(_rotateKey);
    await prefs.remove(_cropKey);
  }

  bool get isSet => url.isNotEmpty;

  /// Short form for the status pill: the host, without scheme or path.
  String get label {
    if (url.isEmpty) return 'tap to set server';
    final u = url.replaceFirst(RegExp(r'^https?://'), '');
    return u.split('/').first;
  }
}
