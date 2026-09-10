// One place for colour and type.
//
// Dark by default because the app is used looking at metal under shop lighting,
// and because every view is dominated by a photograph — a light chrome would
// fight the image for attention.
//
// Poppins comes from google_fonts, which fetches and caches on first launch.
// The app already needs the network to do anything, so that is not a new
// dependency in practice.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class WeldzColors {
  /// Primary. Used for actions and the active state, nothing decorative.
  static const blue = Color(0xFF2F7FF0);
  static const blueDim = Color(0xFF1F5FBF);

  static const bg = Color(0xFF0A0E13);
  static const surface = Color(0xFF121A23);
  static const surfaceHigh = Color(0xFF18222D);
  static const border = Color(0xFF1F2A36);

  static const text = Color(0xFFE8EDF2);
  static const textDim = Color(0xFF8A98A6);
  static const textFaint = Color(0xFF5A6874);

  static const good = Color(0xFF2ECC71);
  static const warn = Color(0xFFF1C40F);
  static const bad = Color(0xFFE74C3C);

  /// Class palette, matching the server's overlay.py so a phone screenshot and
  /// a desktop prediction of the same weld read identically.
  static const classes = <String, Color>{
    // Mirrors weldz-server/overlay.py COLORS, which carries the full rationale.
    // Short version: eight hues cannot all be told apart under colour blindness,
    // so the palette is arranged such that every confusable pair leads to the
    // same verdict (crack/discontinuity both reject, porosity/spatter both
    // acceptable), and the four classes present on every frame were validated
    // as a set. Keep in step with overlay.py, charts.js and inf-test/common.py.
    'crack': Color(0xFFE66767),          // red    -- reject
    'discontinuity': Color(0xFFD95926),  // orange -- reject
    'undercut': Color(0xFFC98500),       // amber  -- rework
    'porosity': Color(0xFF008300),       // green  -- acceptable
    'spatter': Color(0xFF199E70),        // aqua   -- acceptable
    'overlap': Color(0xFF9085E9),        // violet -- acceptable
    'weld_seam': Color(0xFF3987E5),      // blue   -- structure
    'workpiece': Color(0xFFE0479E),      // pink   -- structure
  };

  static Color forClass(String label) => classes[label] ?? const Color(0xFFC8C8C8);

  /// Large regions. Listed after the defects and drawn more faintly — they
  /// cover most of the frame and are context, not findings.
  static const structural = {'workpiece', 'weld_seam'};
  static bool isStructural(String label) => structural.contains(label);
}

ThemeData weldzTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: WeldzColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: WeldzColors.blue,
      onPrimary: Colors.white,
      surface: WeldzColors.surface,
      onSurface: WeldzColors.text,
      error: WeldzColors.bad,
    ),
    textTheme: GoogleFonts.poppinsTextTheme(base.textTheme).apply(
      bodyColor: WeldzColors.text,
      displayColor: WeldzColors.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: WeldzColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    dividerTheme: const DividerThemeData(
      color: WeldzColors.border,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      color: WeldzColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: WeldzColors.border),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WeldzColors.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WeldzColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WeldzColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: WeldzColors.blue, width: 1.6),
      ),
      labelStyle: const TextStyle(color: WeldzColors.textDim),
      helperStyle: const TextStyle(color: WeldzColors.textFaint, fontSize: 11),
      helperMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WeldzColors.blue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WeldzColors.text,
        side: const BorderSide(color: WeldzColors.border),
        minimumSize: const Size(0, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: WeldzColors.surfaceHigh,
      contentTextStyle: GoogleFonts.poppins(
          color: WeldzColors.text, fontSize: 13),
      actionTextColor: WeldzColors.blue,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: WeldzColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: WeldzColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: WeldzColors.blue.withValues(alpha: 0.18),
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => GoogleFonts.poppins(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? WeldzColors.blue
                : WeldzColors.textDim,
          )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? WeldzColors.blue
                : WeldzColors.textDim,
          )),
    ),
  );
}

/// Numbers use tabular figures so a column of millimetres does not jitter as
/// digits change.
TextStyle weldzMono({double size = 13, FontWeight weight = FontWeight.w600, Color? color}) =>
    GoogleFonts.poppins(
      fontSize: size,
      fontWeight: weight,
      color: color ?? WeldzColors.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// Section heading, shared by the three pages so they line up.
class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w600, height: 1.1)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!,
                        style: const TextStyle(
                            fontSize: 12, color: WeldzColors.textDim)),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}
