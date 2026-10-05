import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The colour tokens from the design. Use these names, never raw hex values.
class AppColors {
  static const pine900 = Color(0xFF0A3D30);
  static const pine700 = Color(0xFF0F5A47);
  static const pine500 = Color(0xFF2E8268);
  static const pine100 = Color(0xFFDCEBE4);
  static const amber500 = Color(0xFFF2B33D);
  static const amber100 = Color(0xFFFFF1CC);
  static const amber900 = Color(0xFF3D2A00);
  static const ink = Color(0xFF10201B);
  static const slate = Color(0xFF4D5C56);
  static const lineStrong = Color(0xFFBFC9C1);
  static const line = Color(0xFFD9E0DA);
  static const mist = Color(0xFFE3E9E4);
  static const ground = Color(0xFFF3F5F1);
  static const surface = Color(0xFFFFFFFF);
  static const personal = Color(0xFF33478F);
  static const personalBg = Color(0xFFE3E7F6);
  static const pending = Color(0xFF8A4B00);
  static const pendingBg = Color(0xFFFFE8CC);
  static const error = Color(0xFFB3261E);
  static const errorBg = Color(0xFFFBE4E1);
  static const personalDark = Color(0xFF22306A);
}

/// Endless decorative animations (the AI glow). Tests turn them off so they
/// can wait for the screen to settle.
class AppMotion {
  static bool loops = true;
}

/// The soft shadow used under raised cards.
const cardShadow = [BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 8))];

/// Text styles. Bricolage Grotesque for balances and titles, Instrument Sans
/// for everything else.
class AppText {
  /// Tests turn this off so google_fonts does not try to download fonts.
  static bool useGoogleFonts = true;

  static TextStyle _display(double size, double height, Color color) {
    final base = TextStyle(fontSize: size, height: height / size, fontWeight: FontWeight.w700, color: color);
    return useGoogleFonts ? GoogleFonts.getFont('Bricolage Grotesque', textStyle: base) : base;
  }

  static TextStyle _sans(double size, double height, FontWeight weight, Color color) {
    final base = TextStyle(fontSize: size, height: height / size, fontWeight: weight, color: color);
    return useGoogleFonts ? GoogleFonts.getFont('Instrument Sans', textStyle: base) : base;
  }

  static TextStyle balance({Color color = AppColors.ink}) => _display(40, 48, color);
  static TextStyle title({Color color = AppColors.ink}) => _display(28, 32, color);
  static TextStyle hero({Color color = AppColors.ink}) => _display(34, 40, color);
  static TextStyle heading({Color color = AppColors.ink}) => _sans(17, 22, FontWeight.w600, color);
  static TextStyle body({Color color = AppColors.ink, FontWeight weight = FontWeight.w400}) =>
      _sans(15, 20, weight, color);
  static TextStyle detail({Color color = AppColors.slate, FontWeight weight = FontWeight.w400}) =>
      _sans(13, 18, weight, color);
  static TextStyle small({Color color = AppColors.slate, FontWeight weight = FontWeight.w500}) =>
      _sans(12, 16, weight, color);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.pine700,
    primary: AppColors.pine700,
    onPrimary: Colors.white,
    secondary: AppColors.amber500,
    surface: AppColors.surface,
    error: AppColors.error,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.ground,
    // Instrument Sans for every widget that does not set its own style.
    fontFamily: AppText.useGoogleFonts ? GoogleFonts.getFont('Instrument Sans').fontFamily : null,
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.ground,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppText.heading(),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.pine700,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: AppText.body(weight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.pine700,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: AppColors.lineStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: AppText.body(weight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.lineStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.lineStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.pine700, width: 2),
      ),
    ),
    // Pages slide and fade in the same way everywhere.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
    dividerTheme: const DividerThemeData(color: AppColors.line, space: 1),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.pine100,
      side: const BorderSide(color: AppColors.line),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.pine700,
      unselectedLabelColor: AppColors.slate,
      indicatorColor: AppColors.pine700,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.pine700 : null),
    ),
  );
}
