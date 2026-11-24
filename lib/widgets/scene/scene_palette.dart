import 'package:flutter/material.dart';

/// 场景体系的配色板：同时提供深色与浅色两套，跟随编辑器主题切换。
///
/// 用法：在 build 中 `final p = ScenePalette.of(context);`，
/// 再用 `p.textPrimary` / `p.glassFill` 等取色；尺寸与动效仍用 [SceneTokens]。
class ScenePalette {
  const ScenePalette({
    required this.isDark,
    required this.bgTop,
    required this.bgBottom,
    required this.glassFill,
    required this.glassFillStrong,
    required this.glassBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.shadow,
    required this.codeBackground,
    required this.codeForeground,
    required this.inputFill,
    required this.divider,
  });

  /// 当前是否为深色主题。
  final bool isDark;

  final Color bgTop;
  final Color bgBottom;
  final Color glassFill;
  final Color glassFillStrong;
  final Color glassBorder;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color shadow;
  final Color codeBackground;
  final Color codeForeground;
  final Color inputFill;
  final Color divider;

  /// 深色玻璃拟态（默认）。
  static const ScenePalette dark = ScenePalette(
    isDark: true,
    bgTop: Color(0xFF0A0A0C),
    bgBottom: Color(0xFF111114),
    glassFill: Color(0x0DFFFFFF),
    glassFillStrong: Color(0x14FFFFFF),
    glassBorder: Color(0x1AFFFFFF),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0xB3FFFFFF),
    textTertiary: Color(0x66FFFFFF),
    shadow: Color(0x59000000),
    codeBackground: Color(0xFF141418),
    codeForeground: Color(0xFFE6E6EB),
    inputFill: Color(0x14FFFFFF),
    divider: Color(0x1AFFFFFF),
  );

  /// 浅色（白天）主题：保留玻璃质感，改用浅底与深色文字。
  static const ScenePalette light = ScenePalette(
    isDark: false,
    bgTop: Color(0xFFF7F7FA),
    bgBottom: Color(0xFFEDEFF4),
    glassFill: Color(0xCCFFFFFF),
    glassFillStrong: Color(0xF2FFFFFF),
    glassBorder: Color(0x14000000),
    textPrimary: Color(0xFF14151A),
    textSecondary: Color(0xCC1A1A1F),
    textTertiary: Color(0x991A1A1F),
    shadow: Color(0x1F1A1A1F),
    codeBackground: Color(0xF2FFFFFF),
    codeForeground: Color(0xFF24252B),
    inputFill: Color(0x0F000000),
    divider: Color(0x14000000),
  );

  /// 根据当前 [Theme] 的明暗返回对应色板。
  static ScenePalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  /// 页面背景渐变。
  LinearGradient get backgroundGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [bgTop, bgBottom],
  );

  /// 玻璃卡装饰。
  ///
  /// [accent] 仅在 [glow] 为 true 时参与描边与光晕。
  BoxDecoration glassDecoration({
    Color? accent,
    double radius = 24,
    bool glow = false,
    Color? color,
  }) {
    final hasAccent = glow && accent != null;
    return BoxDecoration(
      color: color ?? glassFill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: hasAccent ? accent.withValues(alpha: 0.32) : glassBorder,
      ),
      boxShadow: [
        if (hasAccent)
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.20 : 0.18),
            blurRadius: 36,
            spreadRadius: -4,
          ),
        BoxShadow(
          color: shadow,
          blurRadius: isDark ? 24 : 18,
          offset: Offset(0, isDark ? 12 : 8),
        ),
      ],
    );
  }
}
