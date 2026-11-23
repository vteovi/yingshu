import 'package:flutter/material.dart';

/// 语义化配色：深色为 OLED 纯黑（背景与卡片均为 #000000，屏幕像素不发光），
/// 浅色为白底深字。所有页面统一从这里取色，避免写死 Colors.white。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
  });

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;

  /// OLED 纯黑：所有大面积底色都是纯黑。
  static const AppPalette oled = AppPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF000000),
    surfaceHigh: Color(0xFF0B1220),
    border: Color(0xFF1A2436),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xB3FFFFFF),
    textFaint: Color(0x61FFFFFF),
  );

  /// 浅色：白底深字。
  static const AppPalette light = AppPalette(
    background: Color(0xFFF3F6FC),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFEAF0FB),
    border: Color(0xFFD6E1F5),
    textPrimary: Color(0xFF10182A),
    textSecondary: Color(0xFF55607A),
    textFaint: Color(0xFF97A2B8),
  );

  bool get isDark => background.computeLuminance() < 0.3;

  @override
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceHigh,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textFaint,
  }) {
    return AppPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textFaint: textFaint ?? this.textFaint,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
    );
  }
}

extension AppPaletteX on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ??
      (Theme.of(this).brightness == Brightness.dark ? AppPalette.oled : AppPalette.light);
}
