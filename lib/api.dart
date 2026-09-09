// Talking to the weldz server.
//
// One multipart POST carrying the JPEG, the depth map and the intrinsics. The
// server runs RF-DETR, fuses the masks with the depth, draws the overlay, and
// returns a finished image plus numbers -- so nothing here does any coordinate
// arithmetic.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'capture.dart';

class Detection {
  const Detection({
    required this.label,
    required this.confidence,
    this.widthMm,
    this.heightMm,
    this.areaMm2,
    this.distanceM,
    this.depthFill,
    this.uncertaintyMm,
  });

  final String label;
  final double confidence;
  final double? widthMm, heightMm, areaMm2, distanceM, uncertaintyMm;

  /// Fraction of the mask that had a usable depth reading. A size resting on a
  /// handful of pixels deserves to be flagged, not hidden.
  final double? depthFill;

  bool get hasSize => widthMm != null && heightMm != null;

  String get sizeLabel => hasSize
      ? '${widthMm!.toStringAsFixed(1)} x ${heightMm!.toStringAsFixed(1)} mm'
      : 'no depth';

  factory Detection.fromJson(Map<String, dynamic> j) {
    double? f(String k) => (j[k] as num?)?.toDouble();
    return Detection(
      label: j['label'] as String? ?? '?',
      confidence: f('confidence') ?? 0,
      widthMm: f('width_mm'),
      heightMm: f('height_mm'),
      areaMm2: f('area_mm2'),
      distanceM: f('distance_m'),
      depthFill: f('depth_fill'),
      uncertaintyMm: f('uncertainty_mm'),
    );
  }
}

class Report {
  const Report({
    required this.annotated,
    required this.detections,
    required this.timingMs,
  });

  /// The capture with masks and boxes already drawn, from the server.
  final Uint8List annotated;
  final List<Detection> detections;
  final Map<String, int> timingMs;

  int get serverMs => timingMs['total'] ?? 0;
}

class ApiError implements Exception {
  const ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

class Api {
  Api(this.baseUrl);

  final String baseUrl;

  /// Generous: RF-DETR at 1272 plus an upload on a phone network.
  static const timeout = Duration(seconds: 45);

  Uri _url(String path) {
    var base = baseUrl.trim();
    if (base.isEmpty) throw const ApiError('no server URL set');
    if (!base.startsWith('http')) base = 'https://$base';
    return Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  Future<bool> health() async {
    try {
      final r = await http.get(_url('/health')).timeout(timeout);
      return r.statusCode == 200 &&
          (jsonDecode(r.body) as Map<String, dynamic>)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Report> measure(Capture c, {double confidence = 0.25}) async {
    final req = http.MultipartRequest('POST', _url('/measure'))
      ..fields['meta'] = jsonEncode({
        'image_width': c.imageWidth,
        'image_height': c.imageHeight,
        'depth_width': c.depthWidth,
        'depth_height': c.depthHeight,
        'fx': c.fx,
        'fy': c.fy,
        'cx': c.cx,
        'cy': c.cy,
        'conf': confidence,
      })
      ..files.add(http.MultipartFile.fromBytes('color', c.jpeg,
          filename: 'color.jpg'))
      ..files.add(http.MultipartFile.fromBytes('depth', c.depth,
          filename: 'depth.u16'))
      ..files.add(http.MultipartFile.fromBytes('confidence', c.confidence,
          filename: 'conf.u8'));

    late http.Response res;
    try {
      // Both halves need the timeout: send() covers the upload, fromStream the
      // response body. Timing only the second leaves a stalled upload hanging.
      final streamed = await req.send().timeout(timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout);
    } catch (e) {
      throw ApiError('could not reach the server: $e');
    }

    if (res.statusCode != 200) {
      // FastAPI puts the reason in `detail`; surface it rather than a bare code
      String detail = res.body;
      try {
        detail = (jsonDecode(res.body) as Map<String, dynamic>)['detail']
                ?.toString() ??
            res.body;
      } catch (_) {}
      throw ApiError('server said ${res.statusCode}: $detail');
    }

    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return Report(
      annotated: base64Decode(j['annotated'] as String),
      detections: (j['detections'] as List)
          .map((d) => Detection.fromJson(d as Map<String, dynamic>))
          .toList(),
      timingMs: (j['timing_ms'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toInt())),
    );
  }
}
