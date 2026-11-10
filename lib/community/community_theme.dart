import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

/// 社区区域统一视觉：TDesign 默认 Token + 品牌蓝
class CommunityTheme {
  CommunityTheme._();

  static const brand = Color(0xFF0052D9);
  static const bg = Color(0xFFF3F3F3);
  static const card = Colors.white;
  static const textPrimary = Color(0xE6000000);
  static const textSecondary = Color(0x99000000);
  static const border = Color(0xFFE7E7E7);

  /// 只在社区子树安装 TThemeData，不影响 App 全局 Material 主题
  static Widget wrap(BuildContext context, Widget child) {
    final base = TThemeData.defaultData();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final token = dark ? (base.dark ?? base) : base;
    return Theme(
      data: Theme.of(context).mergeExtension(token),
      child: child,
    );
  }
}
