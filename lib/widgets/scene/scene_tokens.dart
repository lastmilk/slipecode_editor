import 'package:flutter/material.dart';

import 'scene_palette.dart';

/// 场景体系的视觉令牌：圆角、间距、动效，以及深色默认色值。
///
/// 需要跟随编辑器明暗主题时，请用 `ScenePalette.of(context)` 取色；
/// 本类中的颜色常量仅作为深色主题下的兼容默认值。
/// 场景专属强调色不放在这里，由各 [SceneDefinition] 自带。
class SceneTokens {
  SceneTokens._();

  /// 当前上下文的配色板（跟随编辑器白天/黑夜）。
  static ScenePalette of(BuildContext context) => ScenePalette.of(context);

  // ---------------- 背景 ----------------

  /// 背景顶部底色。
  static const Color bgTop = Color(0xFF0A0A0C);

  /// 背景底部底色。
  static const Color bgBottom = Color(0xFF111114);

  /// 页面背景渐变。
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [bgTop, bgBottom],
  );

  // ---------------- 玻璃 ----------------

  /// 玻璃填充（5% 白）。
  static const Color glassFill = Color(0x0DFFFFFF);

  /// 玻璃描边（10% 白）。
  static const Color glassBorder = Color(0x1AFFFFFF);

  /// 强调态的玻璃填充（8% 白）。
  static const Color glassFillStrong = Color(0x14FFFFFF);

  // ---------------- 文本 ----------------

  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xB3FFFFFF);
  static const Color textTertiary = Color(0x66FFFFFF);

  // ---------------- 尺寸 ----------------

  static const double radiusLarge = 28;
  static const double radiusMedium = 24;
  static const double radiusSmall = 16;
  static const double pagePadding = 48;
  static const double gap = 16;

  // ---------------- 动效 ----------------

  static const Duration durationFast = Duration(milliseconds: 180);
  static const Duration durationNormal = Duration(milliseconds: 300);
  static const Duration durationPage = Duration(milliseconds: 240);
  static const Curve curve = Curves.easeOutCubic;

  /// 玻璃卡装饰。
  ///
  /// [accent] 仅在 [glow] 为 true 时参与描边与光晕。
  static BoxDecoration glassDecoration({
    Color? accent,
    double radius = radiusMedium,
    bool glow = false,
  }) {
    final hasAccent = glow && accent != null;
    return BoxDecoration(
      color: glassFill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: hasAccent ? accent.withValues(alpha: 0.32) : glassBorder,
      ),
      boxShadow: [
        if (hasAccent)
          BoxShadow(
            color: accent.withValues(alpha: 0.20),
            blurRadius: 36,
            spreadRadius: -4,
          ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 24,
          offset: const Offset(0, 12),
        ),
      ],
    );
  }

  // ---------------- 文本样式 ----------------

  /// 场景标题（英文主标题 / 页面标题）。
  static TextStyle sceneTitle(double size, {Color color = textPrimary}) {
    return TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: color,
      height: 1.05,
      letterSpacing: -0.8,
    );
  }

  /// 正文 / 描述。
  static TextStyle sceneBody(
    double size, {
    Color color = textSecondary,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: 1.4,
    );
  }

  /// 辅助说明 / 角标。
  static TextStyle sceneCaption(
    double size, {
    Color color = textTertiary,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: 1.4,
      letterSpacing: 0.2,
    );
  }
}
