import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../providers/settings_provider.dart';

/// 应用主题背景图片
///
/// 读取偏好设置中的背景图片配置，若已设置且文件存在，
/// 则将图片以指定不透明度渲染为 [child] 底下的装饰背景，
/// 否则直接返回 [child]，不影响前景可读性。
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.isIdeScreen = false,
  });

  /// 叠加在背景图之上的页面内容
  final Widget child;

  /// 当前页面是否为 IDE 编辑器界面（EditorScreen）
  final bool isIdeScreen;

  /// 便捷包装方法：根据显示范围决定是否渲染背景图
  static Widget wrap({required Widget child, required bool isIdeScreen}) {
    return AppBackground(isIdeScreen: isIdeScreen, child: child);
  }

  /// 判断当前页面是否需要显示背景图
  static bool shouldShow(AppSettings settings, {required bool isIdeScreen}) {
    if (settings.backgroundImagePath.isEmpty) return false;
    // 显示范围为「仅 IDE 编辑器界面」时，非编辑器页不显示
    if (settings.backgroundImageScope == AppSettings.backgroundScopeIdeOnly &&
        !isIdeScreen) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>().settings;
    if (!shouldShow(settings, isIdeScreen: isIdeScreen)) return child;

    final file = File(settings.backgroundImagePath);
    if (!file.existsSync()) return child;

    return Stack(
      children: [
        // 底层背景图：低不透明度 + 铺满，作为页面装饰
        Positioned.fill(
          child: Opacity(
            opacity: settings.backgroundImageOpacity.clamp(0.0, 1.0),
            child: Image.file(file, fit: BoxFit.cover),
          ),
        ),
        child,
      ],
    );
  }
}
