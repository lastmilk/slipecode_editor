import 'package:flutter/material.dart';

import '../../screens/build_screen.dart';
import '../../screens/desktop/plugins_screen.dart';
import '../../screens/desktop/toolchain_screen.dart';
import '../../screens/loader_build_screen.dart';
import '../../screens/settings_screen.dart';
import '../../services/desktop_platform.dart';

/// 桌面端统一「弹出式窗口」宿主。
///
/// 构建、偏好设置、依赖（工具链）、插件市场这类功能不再整页跳转，
/// 而是以大尺寸模态窗口出现；移动端仍保持整页导航。
Future<void> showScreenDialog(
  BuildContext context,
  Widget screen, {
  double maxWidth = 1120,
  double maxHeight = 840,
}) {
  if (!DesktopPlatform.isDesktop) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }
  final size = MediaQuery.sizeOf(context);
  final width = size.width * 0.94 < maxWidth ? size.width * 0.94 : maxWidth;
  final height = size.height * 0.92 < maxHeight ? size.height * 0.92 : maxHeight;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(width: width, height: height, child: screen),
    ),
  );
}

/// 偏好设置弹窗。
Future<void> showSettingsDialog(BuildContext context) => showScreenDialog(
      context,
      const SettingsScreen(),
      maxWidth: 1160,
      maxHeight: 860,
    );

/// 构建弹窗（云端 / Loader 构建）。
Future<void> showBuildDialog(BuildContext context, {bool loader = false}) =>
    showScreenDialog(
      context,
      loader ? const LoaderBuildScreen() : const BuildScreen(),
      maxWidth: 1120,
      maxHeight: 840,
    );

/// 依赖 / 工具链弹窗（Flutter、Dart、Node、JDK 安装与切换）。
Future<void> showToolchainDialog(BuildContext context) => showScreenDialog(
      context,
      const ToolchainScreen(),
      maxWidth: 1040,
      maxHeight: 820,
    );

/// 插件市场弹窗。
Future<void> showPluginsDialog(BuildContext context) => showScreenDialog(
      context,
      const PluginsScreen(),
      maxWidth: 1040,
      maxHeight: 820,
    );
