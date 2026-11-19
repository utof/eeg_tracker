// Night palette: a ship's bridge on the night watch. Warm chart-table black, parchment ink, and the
// navigation-light trio dimmed for dark-adapted eyes: green = live and good, amber = caution,
// red = problem. Low luminance and little blue light, so a glance at 3 a.m. does not wake anyone.
import 'package:flutter/material.dart';

abstract final class Night {
  static const ground = Color(0xFF100D0B);
  static const surface = Color(0xFF18140F);
  static const surfaceHigh = Color(0xFF211B15);
  static const ink = Color(0xFFDCCDB6); // 12:1 on ground
  static const inkMuted = Color(0xFFA99A84); // 7:1, labels and secondary text
  static const rule = Color(0xFF3A322A); // hairlines
  static const track = Color(0xFF26201A); // empty cells
  static const saved = Color(0xFF8C7F6C); // a fully saved half hour: visible, never bright
  static const live = Color(0xFF7FC49A); // starboard green
  static const liveFill = Color(0xFF2E6B4B); // the Start button
  static const onLiveFill = Color(0xFFE8F3EC); // 5.6:1 on liveFill
  static const caution = Color(0xFFE0AE5C); // amber
  static const problem = Color(0xFFE57A63); // port red, dimmed
}

const List<FontFeature> tabular = [FontFeature.tabularFigures()];

// The bottom bar's icons and labels, made once: a theme that is rebuilt equal never animates (MaterialApp's
// AnimatedTheme lerps between unequal themes, and a closure made anew is never equal).
final WidgetStateProperty<IconThemeData?> _barIcons = WidgetStateProperty.resolveWith(
  (s) => IconThemeData(size: 24, color: s.contains(WidgetState.selected) ? Night.ink : Night.inkMuted),
);
final WidgetStateProperty<TextStyle?> _barLabels = WidgetStateProperty.resolveWith(
  (s) => TextStyle(
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.5,
    color: s.contains(WidgetState.selected) ? Night.ink : Night.inkMuted,
    fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
  ),
);

ThemeData nightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Night.live,
    onPrimary: Color(0xFF0E2418),
    primaryContainer: Night.liveFill,
    onPrimaryContainer: Night.onLiveFill,
    secondary: Night.caution,
    onSecondary: Color(0xFF2A1C05),
    error: Night.problem,
    onError: Color(0xFF2B0D06),
    surface: Night.ground,
    onSurface: Night.ink,
    onSurfaceVariant: Night.inkMuted,
    surfaceContainerLowest: Night.ground,
    surfaceContainerLow: Night.surface,
    surfaceContainer: Night.surface,
    surfaceContainerHigh: Night.surfaceHigh,
    surfaceContainerHighest: Night.surfaceHigh,
    outline: Night.inkMuted,
    outlineVariant: Night.rule,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, scaffoldBackgroundColor: Night.ground);
  final text = base.textTheme.apply(bodyColor: Night.ink, displayColor: Night.ink);
  // Button labels keep the theme's family; only size and weight change.
  final big = text.labelLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: 0.1);
  final small = text.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500, letterSpacing: 0.1);
  return base.copyWith(
    textTheme: text.copyWith(
      displayMedium: text.displayMedium?.copyWith(fontFeatures: tabular, height: 1.0, letterSpacing: -0.5),
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.25),
      labelLarge: text.labelLarge?.copyWith(fontSize: 16, letterSpacing: 0.1),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Night.ground,
      foregroundColor: Night.inkMuted,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    dividerTheme: const DividerThemeData(color: Night.rule, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Night.liveFill,
        foregroundColor: Night.onLiveFill,
        disabledBackgroundColor: Night.surfaceHigh,
        disabledForegroundColor: Night.inkMuted,
        minimumSize: const Size.fromHeight(64),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: big,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Night.ink,
        side: const BorderSide(color: Night.inkMuted),
        minimumSize: const Size.fromHeight(64),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: big,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Night.ink, minimumSize: const Size(64, 48), textStyle: small),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Night.surfaceHigh),
    // the main screen's bottom bar (home_tabs.dart): one ply on the ground, the chosen tab one step lighter
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Night.ground,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      height: 72,
      indicatorColor: Night.rule,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: _barIcons,
      labelTextStyle: _barLabels,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Night.surfaceHigh,
      contentTextStyle: text.bodyLarge?.copyWith(color: Night.ink),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
