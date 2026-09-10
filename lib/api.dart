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
import 'roi.dart';
import 'settings.dart';

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
    this.maskPng,
  });

  final String label;
  final double confidence;
  final double? widthMm, heightMm, areaMm2, distanceM, uncertaintyMm;

  /// Fraction of the mask that had a usable depth reading. A size resting on a
  /// handful of pixels deserves to be flagged, not hidden.
  final double? depthFill;

  /// The mask as a PNG, already downsampled server-side to the depth grid.
  /// Used to crop the point cloud; ~300 bytes for a typical blob, which is why
  /// it is cheap enough to ship at all.
  final Uint8List? maskPng;

  bool get hasMask => maskPng != null && maskPng!.isNotEmpty;

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
      maskPng:
          j['mask_png'] is String ? base64Decode(j['mask_png'] as String) : null,
    );
  }
}

class Report {
  const Report({
    required this.annotated,
    required this.detections,
    required this.timingMs,
    this.judgement = Judgement.empty,
    this.assessment = const Assessment(status: 'disabled'),
    this.roi,
  });

  /// The capture with masks and boxes already drawn, from the server.
  final Uint8List annotated;
  final List<Detection> detections;
  final Map<String, int> timingMs;

  /// The rule table's decision. This is the answer a person acts on.
  final Judgement judgement;

  /// The VLM's explanation of that decision. Advisory only.
  final Assessment assessment;

  /// The region the server analysed, or null if it analysed the whole frame.
  /// Everything the report carries — the overlay, the boxes, the masks — is in
  /// this region's coordinates, so anything drawn beside them has to be cut
  /// down to it first.
  final Roi? roi;

  int get serverMs => timingMs['total'] ?? 0;

  /// The workpiece mask, for cropping the point cloud to the part. Falls back
  /// to the weld seam, then to nothing — a full-frame cloud is a reasonable
  /// answer when the model found no structure to crop to.
  Uint8List? get cropMask {
    for (final want in ['workpiece', 'weld_seam']) {
      for (final d in detections) {
        if (d.label == want && d.hasMask) return d.maskPng;
      }
    }
    return null;
  }

  String get cropLabel {
    for (final want in ['workpiece', 'weld_seam']) {
      if (detections.any((d) => d.label == want && d.hasMask)) return want;
    }
    return 'none';
  }
}

class ApiError implements Exception {
  const ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

class Api {
  Api(this.baseUrl, {this.token = ''});

  final String baseUrl;

  /// Sent as `X-Weldz-Token` when non-empty. The server only enforces it if it
  /// was started with WELDZ_TOKEN set, so an empty token stays compatible with
  /// an open server.
  final String token;

  Map<String, String> get _headers =>
      token.isEmpty ? const {} : {'X-Weldz-Token': token};

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
      final r = await http.get(_url('/health'), headers: _headers).timeout(timeout);
      return r.statusCode == 200 &&
          (jsonDecode(r.body) as Map<String, dynamic>)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// [settings] supplies the threshold and the pre-inference geometry. The
  /// server clamps the threshold again and snaps the crop to a size whose edges
  /// land on whole depth pixels, so what comes back in `Report.geometry` is
  /// what actually happened -- not necessarily what was asked for.
  Future<Report> measure(Capture c, {Settings? settings}) async {
    final req = http.MultipartRequest('POST', _url('/measure'))
      ..headers.addAll(_headers)
      ..fields['meta'] = jsonEncode({
        'image_width': c.imageWidth,
        'image_height': c.imageHeight,
        'depth_width': c.depthWidth,
        'depth_height': c.depthHeight,
        'fx': c.fx,
        'fy': c.fy,
        'cx': c.cx,
        'cy': c.cy,
        'conf': settings?.conf ?? Settings.defaultConf,
        'rotate': settings?.rotate ?? Settings.defaultRotate,
        'crop': settings?.crop ?? Settings.defaultCrop,
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

    if (res.statusCode == 401) {
      throw const ApiError('server rejected the token — check it in settings');
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
      judgement: j['judgement'] is Map
          ? Judgement.fromJson(j['judgement'] as Map<String, dynamic>)
          : Judgement.empty,
      assessment: j['assessment'] is Map
          ? Assessment.fromJson(j['assessment'] as Map<String, dynamic>)
          : const Assessment(status: 'disabled'),
      // Null on an older server, or when it analysed the whole frame. Every
      // consumer treats null as "no crop" rather than failing, so the app keeps
      // working against either.
      roi: Roi.from(j['geometry']),
    );
  }
}

/// The verdict, decided by the server's rule table. Never by the VLM.
enum Verdict {
  approve('Approve'),
  rework('Rework'),
  reject('Reject');

  const Verdict(this.label);
  final String label;

  static Verdict parse(String? s) => switch (s) {
        'reject' => Verdict.reject,
        'rework' => Verdict.rework,
        _ => Verdict.approve,
      };
}

/// One rule's outcome, so the app can show what was checked — including the
/// rules that passed. An APPROVE that lists nothing looks like a failure to
/// look; an APPROVE that lists three clear checks looks like an inspection.
class RuleCheck {
  const RuleCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    this.reason,
  });

  final String id;
  final String title;

  /// `clear`, `fired`, or `unmeasured`.
  final String status;
  final String detail;
  final String? reason;

  bool get fired => status == 'fired';
  bool get unmeasured => status == 'unmeasured';

  factory RuleCheck.fromJson(Map<String, dynamic> j) => RuleCheck(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        status: j['status'] as String? ?? 'clear',
        detail: j['detail'] as String? ?? '',
        reason: j['reason'] as String?,
      );
}

/// One tunable rule's standing: what was measured, its limit, and how close
/// the two are. `utilisation` is normalised so 1.0 always means "at the limit"
/// whichever way the comparator points, which is what lets a single bar render
/// a `<=` rule and a `>=` rule without one of them reading backwards.
class Utilisation {
  const Utilisation({
    required this.id,
    required this.name,
    required this.status,
    required this.detail,
    this.utilisation,
    this.value,
    this.limit,
  });

  final String id;
  final String name;

  /// `clear`, `breached`, or `indeterminate`.
  final String status;
  final String detail;

  /// Null when the rule could not be measured -- which is NOT a pass.
  final double? utilisation;
  final double? value;
  final double? limit;

  bool get breached => status == 'breached';
  bool get indeterminate => utilisation == null;

  factory Utilisation.fromJson(Map<String, dynamic> j) => Utilisation(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        status: j['status'] as String? ?? 'clear',
        detail: j['detail'] as String? ?? '',
        utilisation: (j['utilisation'] as num?)?.toDouble(),
        value: (j['value'] as num?)?.toDouble(),
        limit: (j['limit'] as num?)?.toDouble(),
      );
}

class Judgement {
  const Judgement({
    required this.verdict,
    required this.headline,
    required this.checks,
    required this.noted,
    this.score,
    this.utilisations = const [],
    this.binding,
    this.rulesetVersion,
    this.seamStatus,
    this.offSeamIgnored = 0,
  });

  final Verdict verdict;
  final String headline;
  final List<RuleCheck> checks;

  /// Classes that were detected but are acceptable on presence alone.
  final List<String> noted;

  /// Weighted severity. A sound weld carrying three small pores scores a
  /// handful of points; thirty of them does not.
  final double? score;

  final List<Utilisation> utilisations;

  /// The rule closest to its limit -- the one worth naming.
  final Utilisation? binding;

  /// Which editable rule set produced this. Two captures judged under
  /// different versions are not comparable, so it travels with the verdict.
  final int? rulesetVersion;

  /// `ok`, or why the seam could not be measured.
  final String? seamStatus;

  /// Detections the spatial gate set aside as not being on the weld.
  final int offSeamIgnored;

  bool get seamUsable => seamStatus == 'ok';

  static const empty = Judgement(
    verdict: Verdict.approve,
    headline: '',
    checks: [],
    noted: [],
  );

  // Every new field is optional. An older server that knows none of them still
  // produces a Judgement the app renders, which is what lets the server and
  // the phone ship on different days.
  factory Judgement.fromJson(Map<String, dynamic> j) {
    final utils = ((j['utilisations'] as List?) ?? [])
        .map((u) => Utilisation.fromJson(u as Map<String, dynamic>))
        .toList();
    final b = j['binding'];
    return Judgement(
      verdict: Verdict.parse(j['verdict'] as String?),
      headline: j['headline'] as String? ?? '',
      checks: ((j['checks'] as List?) ?? [])
          .map((c) => RuleCheck.fromJson(c as Map<String, dynamic>))
          .toList(),
      noted: ((j['noted'] as List?) ?? []).map((n) => '$n').toList(),
      score: (j['score'] as num?)?.toDouble(),
      utilisations: utils,
      binding: b is Map<String, dynamic> ? Utilisation.fromJson(b) : null,
      rulesetVersion: (j['ruleset_version'] as num?)?.toInt(),
      seamStatus: (j['seam'] as Map<String, dynamic>?)?['status'] as String?,
      offSeamIgnored: (j['off_seam_ignored'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The VLM's read. Advisory: it explains the verdict and never changes it.
class Assessment {
  const Assessment({
    required this.status,
    this.summary = '',
    this.concerns = const [],
    this.imageQuality,
    this.missedRejectable = const [],
    this.usable = true,
    this.beadQuality = const [],
    this.bindingNote = '',
    this.visualFlags = const [],
    this.agreesWithVerdict,
    this.reason = '',
    this.error,
    this.ms,
  });

  /// `ready`, `disabled`, or `failed`.
  final String status;
  final String summary;
  final List<String> concerns;

  /// `good`, `fair`, `poor`, or null when the model did not say.
  final String? imageQuality;

  /// Rejectable defects the VLM says it can see and the detector did not.
  /// Surfaced as a warning; deliberately does NOT change the verdict.
  final List<String> missedRejectable;

  /// The gate. False means the photograph is not good enough to judge from,
  /// and the app says so INSTEAD of showing a verdict -- a grade computed from
  /// a blurred or badly framed capture is worse than no grade.
  final bool usable;

  /// What the bead looks like: uniform, ropey, poor wetting, and so on.
  final List<String> beadQuality;

  /// Where on the weld the tightest rule is. The model is told which rule that
  /// is and what it measured; it points at the place rather than recomputing.
  final String bindingNote;

  final List<String> visualFlags;

  /// The model's own read against the verdict it was given. Null when it did
  /// not say. Disagreement raises a flag for a person; it changes nothing.
  final bool? agreesWithVerdict;
  final String reason;

  final String? error;
  final int? ms;

  bool get isReady => status == 'ready' && summary.isNotEmpty;
  bool get isDisabled => status == 'disabled';
  bool get poorImage => imageQuality == 'poor';

  /// Only a ready assessment can block. A VLM that is off or unreachable must
  /// never stop a capture being shown.
  bool get blocks => status == 'ready' && !usable;
  bool get disagrees => agreesWithVerdict == false;

  factory Assessment.fromJson(Map<String, dynamic> j) => Assessment(
        status: j['status'] as String? ?? 'failed',
        summary: (j['summary'] as String? ?? '').trim(),
        concerns: ((j['concerns'] as List?) ?? []).map((c) => '$c').toList(),
        imageQuality: j['image_quality'] as String?,
        missedRejectable:
            ((j['missed_rejectable'] as List?) ?? []).map((m) => '$m').toList(),
        // defaults to usable: an older service says nothing, and silence must
        // not be read as "this capture is no good"
        usable: j['usable'] as bool? ?? true,
        beadQuality:
            ((j['bead_quality'] as List?) ?? []).map((b) => '$b').toList(),
        bindingNote: (j['binding_rule_note'] as String? ?? '').trim(),
        visualFlags:
            ((j['visual_flags'] as List?) ?? []).map((v) => '$v').toList(),
        agreesWithVerdict: j['agrees_with_verdict'] as bool?,
        reason: (j['reason'] as String? ?? '').trim(),
        error: j['error'] as String?,
        ms: (j['ms'] as num?)?.toInt(),
      );
}
