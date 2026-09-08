// The live ARKit camera feed, hosted as a native view.
//
// There is no live inference behind this. RF-DETR at 1272 is far too heavy to
// run per frame on a phone, so the preview exists purely for aiming, and all
// the work happens on one frame when Capture is pressed.
//
// The session behind it starts with the view and stays up, so a capture is
// instant — no start/warm-up/tear-down round trip.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

class ArPreview extends StatelessWidget {
  const ArPreview({super.key});

  /// Must match ARPreviewFactory's registration id in AppDelegate.swift.
  static const viewType = 'weld/ar_preview';

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isIOS) return const _NoPreview();
    // No creation params: the session is owned by ARSessionManager, not
    // configured per-view, so the factory needs nothing from Dart.
    return const UiKitView(viewType: viewType);
  }
}

/// Android and desktop have no ARKit. The rest of the app still runs against
/// the synthetic source, so this says so plainly instead of showing black.
class _NoPreview extends StatelessWidget {
  const _NoPreview();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF11181F),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.view_in_ar_outlined, size: 42, color: Colors.white24),
              SizedBox(height: 14),
              Text(
                'No ARKit on this platform',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              SizedBox(height: 6),
              Text(
                'Capture returns a synthetic frame',
                style: TextStyle(color: Colors.white30, fontSize: 12),
              ),
            ],
          ),
        ),
      );
}
