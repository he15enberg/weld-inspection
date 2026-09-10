// Aim and capture.
//
// The preview stays mounted while a capture is in flight rather than being
// replaced by a spinner, so the live feed is still there behind the progress —
// it makes a two-second round trip feel like a shutter rather than a stall.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'ar_preview.dart';
import 'capture.dart';
import 'result.dart';
import 'settings.dart';
import 'theme.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _source = CaptureSource();

  bool _busy = false;
  String _status = '';
  Capture? _shot;
  Report? _report;

  Settings _settings =
      const Settings(url: Settings.defaultUrl, token: Settings.defaultToken);

  @override
  void initState() {
    super.initState();
    _reloadSettings();
  }

  Future<void> _reloadSettings() async {
    final s = await Settings.load();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _capture() async {
    // The settings page may have changed the URL since this screen was built,
    // and IndexedStack keeps this state alive, so re-read rather than trust it.
    await _reloadSettings();

    if (!_settings.isSet) {
      final ok = await _askForServer();
      if (!ok) return;
    }

    setState(() {
      _busy = true;
      _status = 'Capturing frame';
    });

    try {
      final shot = await _source.grab();

      if (!mounted) return;
      setState(() => _status =
          'Measuring · ${(shot.bytes / 1024).round()} kB uploading');

      final report =
          await Api(_settings.url, token: _settings.token)
              .measure(shot, settings: _settings);

      if (!mounted) return;
      setState(() {
        _shot = shot;
        _report = report;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 6)),
      );
    }
  }

  /// Asked once, when nothing is stored — not on launch and not per capture.
  Future<bool> _askForServer() async {
    final controller = TextEditingController(text: _settings.url);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'abc-def.trycloudflare.com',
            helperText: 'https:// is assumed · change it later in Settings',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return false;
    await Settings.save(url: url, token: _settings.token);
    await _reloadSettings();
    return true;
  }

  void _back() => setState(() {
        _shot = null;
        _report = null;
      });

  @override
  Widget build(BuildContext context) {
    final shot = _shot, report = _report;
    if (shot != null && report != null) {
      return SafeArea(
        child: ResultView(capture: shot, report: report, onClose: _back),
      );
    }

    return SafeArea(
      child: Stack(
        children: [
          const Positioned.fill(child: ArPreview()),

          // The region that will actually be analysed. Framing is the single
          // biggest lever on detection quality -- the model was trained on
          // welds that fill the frame -- and now that the server crops to a
          // square, anything outside this box is not merely poorly framed, it
          // is never looked at.
          Positioned.fill(
            child: IgnorePointer(child: _Roi(crop: _settings.crop)),
          ),

          // Scrims. A camera view is whatever the room happens to be, so
          // controls over a bare preview are legible against a dark bench and
          // invisible against a bright one. These give every overlay a ground
          // of its own without hiding the scene.
          const Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(child: _Scrim(height: 132, fromTop: true)),
          ),
          const Positioned(
            bottom: 0, left: 0, right: 0,
            child: IgnorePointer(child: _Scrim(height: 210, fromTop: false)),
          ),

          Positioned(
            left: 16, right: 16, top: 14,
            child: IgnorePointer(child: _TopBar(settings: _settings)),
          ),

          if (_busy)
            Positioned(
              left: 0, right: 0, bottom: 132,
              child: Center(child: _Progress(status: _status)),
            ),

          if (!_busy)
            Positioned(
              left: 24, right: 24, bottom: 128,
              child: IgnorePointer(
                child: _Hint(cropped: _settings.crop > 0),
              ),
            ),

          Positioned(
            left: 0, right: 0, bottom: 30,
            child: Center(
              child: _ShutterButton(busy: _busy, onTap: _busy ? null : _capture),
            ),
          ),
        ],
      ),
    );
  }
}

/// Corner brackets over the middle of the frame.
/// The square the server will actually analyse, drawn over the live feed.
///
/// A centred square crop keeps the same pixels whichever way the frame is
/// turned, so the region to draw is simply the centred `crop` square of the
/// camera frame -- the quarter turn does not enter into it.
///
/// ARSCNView aspect-FILLS its bounds: the frame is scaled by the LARGER of the
/// two ratios and the overflow falls off the screen. On a tall phone the sides
/// of a 4:3 frame are already off-screen, which means the analysed square is
/// WIDER than the viewport and its left and right edges cannot be drawn at
/// all. What can be drawn -- and what actually matters -- is the band at the
/// top and bottom that falls outside the square. Only edges that exist on
/// screen are painted, so this stays honest at any screen aspect.
///
/// NOT verified on hardware. Aspect-fill is ARSCNView's documented default but
/// no part of this has run on a device; if the bands sit wrong, this widget is
/// the only place to correct it.
class _Roi extends StatelessWidget {
  const _Roi({required this.crop});

  /// Square crop side in captured pixels, or 0 for no crop.
  final int crop;

  // ARKit's default world-tracking format on this hardware, which every stored
  // capture confirms: 1920 x 1440, presented portrait once turned.
  static const _frameShort = 1440.0;
  static const _frameLong = 1920.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          if (crop <= 0 || c.maxWidth <= 0 || c.maxHeight <= 0) {
            return CustomPaint(painter: _RoiPainter(roi: null));
          }
          final scale = math.max(
              c.maxWidth / _frameShort, c.maxHeight / _frameLong);
          final side = crop * scale;
          return CustomPaint(
            painter: _RoiPainter(
              roi: Rect.fromCenter(
                center: Offset(c.maxWidth / 2, c.maxHeight / 2),
                width: side,
                height: side,
              ),
            ),
          );
        },
      );
}

class _RoiPainter extends CustomPainter {
  _RoiPainter({required this.roi});

  /// Null when cropping is off -- then there is no region to mark and the
  /// overlay draws nothing rather than an aiming box that means nothing.
  final Rect? roi;

  @override
  void paint(Canvas canvas, Size size) {
    final r = roi;
    if (r == null) return;

    // dim what the model will never see
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(r),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.42),
    );

    // The boundary itself, kept faint: it is a reference, not the subject.
    final edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.34)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;

    // Only the edges actually on screen. On a tall phone the square is wider
    // than the viewport, so the two vertical edges genuinely do not exist and
    // drawing them would put a line where there is no boundary.
    final hasTop = r.top > 0;
    final hasBottom = r.bottom < size.height;
    final hasLeft = r.left > 0;
    final hasRight = r.right < size.width;

    if (hasTop) {
      canvas.drawLine(Offset(0, r.top), Offset(size.width, r.top), edge);
    }
    if (hasBottom) {
      canvas.drawLine(Offset(0, r.bottom), Offset(size.width, r.bottom), edge);
    }
    if (hasLeft) {
      canvas.drawLine(Offset(r.left, 0), Offset(r.left, size.height), edge);
    }
    if (hasRight) {
      canvas.drawLine(Offset(r.right, 0), Offset(r.right, size.height), edge);
    }

    // Brackets where two visible edges actually meet. A corner drawn where one
    // of its edges runs off the screen would point at a corner that is not
    // there, which is worse than no bracket at all.
    final bracket = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const arm = 26.0;

    void corner(double x, double y, double dx, double dy) {
      canvas.drawLine(Offset(x, y), Offset(x + arm * dx, y), bracket);
      canvas.drawLine(Offset(x, y), Offset(x, y + arm * dy), bracket);
    }

    if (hasLeft && hasTop) corner(r.left, r.top, 1, 1);
    if (hasRight && hasTop) corner(r.right, r.top, -1, 1);
    if (hasLeft && hasBottom) corner(r.left, r.bottom, 1, -1);
    if (hasRight && hasBottom) corner(r.right, r.bottom, -1, -1);

    // When the square is wider than the screen there are no corners to draw,
    // so the two horizontal boundaries get a short centred tick instead --
    // otherwise the only cue left is a faint hairline.
    if (!hasLeft && !hasRight) {
      final cx = size.width / 2;
      if (hasTop) {
        canvas.drawLine(
            Offset(cx - arm, r.top), Offset(cx + arm, r.top), bracket);
      }
      if (hasBottom) {
        canvas.drawLine(
            Offset(cx - arm, r.bottom), Offset(cx + arm, r.bottom), bracket);
      }
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) => old.roi != roi;
}

/// A soft top/bottom gradient so overlays stay readable over any scene.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.height, required this.fromTop});

  final double height;
  final bool fromTop;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: fromTop ? 0.55 : 0.72),
              Colors.black.withValues(alpha: 0.0),
            ],
          ),
        ),
      );
}

/// What the capture will be, in three words.
///
/// The server address used to live here. It was never tappable and a tunnel
/// hostname is forty characters of noise across the top of a viewfinder --
/// the settings tab is where it belongs. What replaces it is the thing that
/// actually changes between captures: the region and the threshold.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Text(
            'WELDZ',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.4,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          if (!settings.isSet)
            // No URL, just the state. Tapping capture prompts for a server
            // anyway, so this only says "expect to be asked".
            const _Tag(
              icon: Icons.cloud_off,
              text: 'no server',
              colour: WeldzColors.warn,
            )
          else ...[
            if (settings.crop > 0)
              _Tag(icon: Icons.crop_square, text: '${settings.crop}'),
            const SizedBox(width: 7),
            _Tag(
              icon: Icons.tune,
              text: settings.conf.toStringAsFixed(2),
            ),
          ],
        ],
      );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.text, this.colour});

  final IconData icon;
  final String text;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final c = colour ?? Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c.withValues(alpha: 0.9)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: c.withValues(alpha: 0.95),
            ),
          ),
        ],
      ),
    );
  }
}

/// The two things that decide whether a capture is worth taking.
///
/// Both were learned the expensive way: the model has only ever seen welds
/// lying across the frame and filling it, and a capture that gets either wrong
/// is not a marginal result, it is a wasted one.
class _Hint extends StatelessWidget {
  const _Hint({required this.cropped});

  final bool cropped;

  @override
  Widget build(BuildContext context) => Text(
        cropped
            ? 'Hold landscape  ·  fill the square with the weld'
            : 'Hold landscape  ·  fill the frame with the weld',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          height: 1.35,
          letterSpacing: 0.2,
          color: Colors.white.withValues(alpha: 0.82),
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 6),
          ],
        ),
      );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: WeldzColors.blue),
            ),
            const SizedBox(width: 11),
            Text(status,
                style: const TextStyle(fontSize: 12, color: WeldzColors.text)),
          ],
        ),
      );
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          // The tap target stays this size whatever the inner disc is doing,
          // so the button does not move under a thumb mid-press.
          width: 86,
          height: 86,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The ring is the shutter; the disc inside it is the state. Two
              // parts rather than one flat circle is what makes it read as a
              // camera control instead of a floating action button.
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: busy ? 0.45 : 0.92),
                    width: 2.5,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: busy ? 54 : 64,
                height: busy ? 54 : 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: busy
                      ? WeldzColors.blue.withValues(alpha: 0.42)
                      : WeldzColors.blue,
                  boxShadow: [
                    BoxShadow(
                      color:
                          WeldzColors.blue.withValues(alpha: busy ? 0.0 : 0.42),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  // Not a camera icon: this does not take a photograph, it
                  // grabs the framed region and sends it to be measured. The
                  // brackets are the same shape as the region on screen.
                  child: Icon(
                    Icons.crop_free_rounded,
                    size: 27,
                    color: Colors.white.withValues(alpha: busy ? 0.55 : 1.0),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
