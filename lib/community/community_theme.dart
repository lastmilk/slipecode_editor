import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

/// 社区区域统一视觉：TDesign Token + 品牌蓝
///
/// 社区页在亮色 / 暗色主题下都必须自成一套完整配色，
/// 否则会出现「半黑半白」（页面底色是浅色、TDesign 组件却是暗色）的问题。
/// [wrap] 会在每次构建时按当前主题切换调色板，页面内部统一取这里的颜色。
class CommunityTheme {
  CommunityTheme._();

  static const brand = Color(0xFF0052D9);

  // 亮色
  static const _lightBg = Color(0xFFF3F3F3);
  static const _lightCard = Colors.white;
  static const _lightTextPrimary = Color(0xE6000000);
  static const _lightTextSecondary = Color(0x99000000);
  static const _lightBorder = Color(0xFFE7E7E7);

  // 暗色
  static const _darkBg = Color(0xFF141417);
  static const _darkCard = Color(0xFF1E1E22);
  static const _darkTextPrimary = Color(0xE6FFFFFF);
  static const _darkTextSecondary = Color(0x99FFFFFF);
  static const _darkBorder = Color(0xFF2C2C31);

  static Color bg = _lightBg;
  static Color card = _lightCard;
  static Color textPrimary = _lightTextPrimary;
  static Color textSecondary = _lightTextSecondary;
  static Color border = _lightBorder;

  static bool isDark = false;

  static void apply(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    isDark = dark;
    bg = dark ? _darkBg : _lightBg;
    card = dark ? _darkCard : _lightCard;
    textPrimary = dark ? _darkTextPrimary : _lightTextPrimary;
    textSecondary = dark ? _darkTextSecondary : _lightTextSecondary;
    border = dark ? _darkBorder : _lightBorder;
  }

  /// 只在社区子树安装 TThemeData，不影响 App 全局 Material 主题
  static Widget wrap(BuildContext context, Widget child) {
    final theme = Theme.of(context);
    apply(theme.brightness);
    final base = TThemeData.defaultData();
    final token = theme.brightness == Brightness.dark
        ? (base.dark ?? base)
        : base;
    return Theme(data: theme.mergeExtension(token), child: child);
  }
}
