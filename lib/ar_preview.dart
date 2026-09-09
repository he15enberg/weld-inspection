// The live ARKit feed, hosted as a native view.
//
// No inference behind it -- the preview is for aiming, and all the work happens
// on one frame when Capture is pressed. Mounting this view is what starts the
// session, so a capture is instant.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

class ArPreview extends StatelessWidget {
  const ArPreview({super.key});

  /// Must match ARPreviewFactory.viewType in AppDelegate.swift.
  static const viewType = 'weldz/ar_preview';

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isIOS) {
      return const ColoredBox(
        color: Color(0xFF11181F),
        child: Center(
          child: Text('ARKit is iOS only',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
        ),
      );
    }
    return const UiKitView(viewType: viewType);
  }
}
