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

          // top strip: where captures go
          Positioned(
            left: 14,
            right: 14,
            top: 12,
            child: _StatusPill(settings: _settings),
          ),

          // The region that will actually be analysed. Framing is the single
          // biggest lever on detection quality -- the model was trained on
          // welds that fill the frame -- and now that the server crops to a
          // square, anything outside this box is not merely poorly framed, it
          // is never looked at.
          Positioned.fill(
            child: IgnorePointer(child: _Roi(crop: _settings.crop)),
          ),

          if (_busy)
            Positioned(
              left: 0,
              right: 0,
              bottom: 104,
              child: Center(child: _Progress(status: _status)),
            ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 26,
            child: Center(
              child: _ShutterButton(busy: _busy, onTap: _busy ? null : _capture),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              settings.isSet ? Icons.cloud_done_outlined : Icons.cloud_off,
              size: 14,
              color: settings.isSet ? WeldzColors.good : WeldzColors.warn,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                settings.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: WeldzColors.text),
              ),
            ),
          ],
        ),
      );
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

    final pen = Paint()
      ..color = Colors.white.withValues(alpha: 0.70)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square;

    // Only the edges actually on screen. On a tall phone the square is wider
    // than the viewport, so the two vertical edges genuinely do not exist and
    // drawing them would put a line where there is no boundary.
    if (r.top > 0) {
      canvas.drawLine(Offset(0, r.top), Offset(size.width, r.top), pen);
    }
    if (r.bottom < size.height) {
      canvas.drawLine(Offset(0, r.bottom), Offset(size.width, r.bottom), pen);
    }
    if (r.left > 0) {
      canvas.drawLine(Offset(r.left, 0), Offset(r.left, size.height), pen);
    }
    if (r.right < size.width) {
      canvas.drawLine(Offset(r.right, 0), Offset(r.right, size.height), pen);
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) => old.roi != roi;
}

class _Progress extends StatelessWidget {
  const _Progress({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(24),
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy
                ? WeldzColors.blue.withValues(alpha: 0.35)
                : WeldzColors.blue,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.85), width: 3),
            boxShadow: [
              BoxShadow(
                color: WeldzColors.blue.withValues(alpha: busy ? 0.0 : 0.45),
                blurRadius: 22,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Center(
            child: Icon(Icons.camera_alt_rounded, size: 30, color: Colors.white),
          ),
        ),
      );
}
