import 'package:flutter/material.dart';

/// Cineseed palette — extracted from the app icon.
/// Deep cinematic purple background with magenta primary and cream accents.
class CineseedColors {
  CineseedColors._();

  // Backgrounds (deep purple, from icon top-left)
  static const Color backgroundDeep = Color(0xFF130824); // darkest
  static const Color background = Color(0xFF1A0B2E); // base
  static const Color surface = Color(0xFF24123F); // cards
  static const Color surfaceHigh = Color(0xFF301850); // raised cards / app bar

  // Brand magenta (from icon bottom-right gradient)
  static const Color primary = Color(0xFFB8336A); // hero magenta
  static const Color primaryDeep = Color(0xFF6B1D8A); // deep purple-magenta
  static const Color primaryBright = Color(0xFFD94E8C); // hover / focus

  // Cream / leaf white (from icon foreground)
  static const Color cream = Color(0xFFF5E8D0);
  static const Color creamMuted = Color(0xFFD9CDB8);

  // Semantic
  static const Color outline = Color(0xFF4A2A6B);
  static const Color outlineSubtle = Color(0x33F5E8D0); // cream @ 20%
}

ThemeData buildCineseedTheme() {
  final colorScheme = const ColorScheme.dark(
    brightness: Brightness.dark,
    primary: CineseedColors.primary,
    onPrimary: CineseedColors.cream,
    primaryContainer: CineseedColors.primaryDeep,
    onPrimaryContainer: CineseedColors.cream,
    secondary: CineseedColors.primaryBright,
    onSecondary: CineseedColors.background,
    secondaryContainer: CineseedColors.surfaceHigh,
    onSecondaryContainer: CineseedColors.cream,
    tertiary: CineseedColors.cream,
    onTertiary: CineseedColors.background,
    surface: CineseedColors.surface,
    onSurface: CineseedColors.cream,
    surfaceContainerLowest: CineseedColors.backgroundDeep,
    surfaceContainerLow: CineseedColors.background,
    surfaceContainer: CineseedColors.surface,
    surfaceContainerHigh: CineseedColors.surfaceHigh,
    surfaceContainerHighest: Color(0xFF3A1F60),
    onSurfaceVariant: CineseedColors.creamMuted,
    outline: CineseedColors.outline,
    outlineVariant: Color(0xFF3A1F60),
    error: Color(0xFFFF6B8B),
    onError: CineseedColors.background,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: CineseedColors.background,
    canvasColor: CineseedColors.background,
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: CineseedColors.background,
      foregroundColor: CineseedColors.cream,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: CineseedColors.cream,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: CineseedColors.cream,
      unselectedLabelColor: CineseedColors.creamMuted,
      indicatorColor: CineseedColors.cream,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3),
      unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500),
      dividerColor: Colors.transparent,
      overlayColor: WidgetStatePropertyAll(Color(0x11F5E8D0)),
    ),
    cardTheme: CardThemeData(
      color: CineseedColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: CineseedColors.outlineSubtle, width: 0.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: CineseedColors.surfaceHigh,
      selectedColor: CineseedColors.primary,
      labelStyle: const TextStyle(
        color: CineseedColors.cream,
        fontWeight: FontWeight.w500,
        fontSize: 12,
      ),
      secondaryLabelStyle: const TextStyle(
        color: CineseedColors.cream,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: CineseedColors.outlineSubtle, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      side: BorderSide.none,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CineseedColors.surface,
      hintStyle: const TextStyle(color: CineseedColors.creamMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CineseedColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CineseedColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(
          color: CineseedColors.primaryBright,
          width: 1.5,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CineseedColors.primary,
        foregroundColor: CineseedColors.cream,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: CineseedColors.primary,
        foregroundColor: CineseedColors.cream,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: CineseedColors.primaryBright,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: CineseedColors.cream,
        hoverColor: CineseedColors.primary.withValues(alpha: 0.15),
      ),
    ),
    iconTheme: const IconThemeData(color: CineseedColors.cream),
    dividerTheme: const DividerThemeData(
      color: CineseedColors.outlineSubtle,
      thickness: 0.5,
      space: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: CineseedColors.primaryBright,
      linearTrackColor: CineseedColors.surfaceHigh,
      circularTrackColor: CineseedColors.surfaceHigh,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: CineseedColors.surfaceHigh,
      contentTextStyle: TextStyle(color: CineseedColors.cream),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: CineseedColors.creamMuted,
      textColor: CineseedColors.cream,
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: CineseedColors.cream,
          displayColor: CineseedColors.cream,
        )
        .copyWith(
          titleLarge: base.textTheme.titleLarge?.copyWith(
            color: CineseedColors.cream,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            color: CineseedColors.cream,
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            color: CineseedColors.creamMuted,
            height: 1.4,
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            color: CineseedColors.creamMuted,
            letterSpacing: 0.4,
          ),
        ),
  );
}

/// Reusable hero gradient (used as a background accent on screens).
const cineseedHeroGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    CineseedColors.background,
    CineseedColors.primaryDeep,
    CineseedColors.primary,
  ],
  stops: [0.0, 0.55, 1.0],
);
