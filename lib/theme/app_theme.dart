import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 主题工厂：深色为 OLED 纯黑，浅色为白底。
class AppTheme {
  static const Color seed = Color(0xFF2F6BFF);
  static const Color seedDark = Color(0xFF7FA6FF);

  static ThemeData dark() => _build(AppPalette.oled, Brightness.dark);
  static ThemeData light() => _build(AppPalette.light, Brightness.light);

  static ThemeData _build(AppPalette palette, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? seedDark : seed;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      secondary: const Color(0xFF3FBFAE),
      surface: palette.surface,
      onSurface: palette.textPrimary,
      outline: palette.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      splashFactory: InkSparkle.splashFactory,
      extensions: <ThemeExtension<dynamic>>[palette],
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: palette.textPrimary,
        ),
        iconTheme: IconThemeData(color: palette.textPrimary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? palette.background : palette.surface,
        indicatorColor: primary.withValues(alpha: 0.22),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? palette.textPrimary : palette.textFaint,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceHigh,
        hintStyle: TextStyle(color: palette.textFaint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primary.withValues(alpha: 0.8), width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceHigh,
        selectedColor: primary.withValues(alpha: 0.28),
        side: BorderSide.none,
        labelStyle: TextStyle(fontSize: 13, color: palette.textSecondary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceHigh,
        contentTextStyle: TextStyle(color: palette.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? palette.surfaceHigh : palette.surface,
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: ListTileThemeData(iconColor: palette.textSecondary),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? palette.surfaceHigh : palette.surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: palette.textPrimary, fontSize: 14),
      ),
    );
  }
}
