import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/app_settings.dart';
import '../providers/settings_provider.dart';

/// 应用主题背景
///
/// 读取偏好设置中的背景配置，若已设置且文件存在，
/// 则按类型渲染为 [child] 底下的装饰背景：
/// - 静态图 / GIF：`Image.file`（GIF 原生支持动图）
/// - MP4：video_player 静音循环播放（仅本地，不上传云端）
/// 否则直接返回 [child]，不影响前景可读性。
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.isIdeScreen = false,
  });

  /// 叠加在背景之上的页面内容
  final Widget child;

  /// 当前页面是否为 IDE 编辑器界面（EditorScreen）
  final bool isIdeScreen;

  /// 便捷包装方法：根据显示范围决定是否渲染背景
  static Widget wrap({required Widget child, required bool isIdeScreen}) {
    return AppBackground(isIdeScreen: isIdeScreen, child: child);
  }

  /// 判断当前页面是否需要显示背景
  static bool shouldShow(AppSettings settings, {required bool isIdeScreen}) {
    if (settings.backgroundImagePath.isEmpty) return false;
    // 显示范围为「仅 IDE 编辑器界面」时，非编辑器页不显示
    if (settings.backgroundImageScope == AppSettings.backgroundScopeIdeOnly &&
        !isIdeScreen) {
      return false;
    }
    return true;
  }

  /// 背景文件是否为视频（MP4 动态壁纸）
  static bool isVideoPath(String path) =>
      path.toLowerCase().endsWith('.mp4');

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>().settings;
    if (!shouldShow(settings, isIdeScreen: isIdeScreen)) return child;

    final path = settings.backgroundImagePath;
    if (!File(path).existsSync()) return child;

    final opacity = settings.backgroundImageOpacity.clamp(0.0, 1.0);
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: opacity,
            child: isVideoPath(path)
                ? _VideoWallpaper(key: ValueKey(path), path: path)
                : Image.file(File(path), fit: BoxFit.cover),
          ),
        ),
        child,
      ],
    );
  }
}

/// MP4 动态壁纸：静音、循环、铺满，无任何控制 UI
class _VideoWallpaper extends StatefulWidget {
  const _VideoWallpaper({super.key, required this.path});

  final String path;

  @override
  State<_VideoWallpaper> createState() => _VideoWallpaperState();
}

class _VideoWallpaperState extends State<_VideoWallpaper> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..setLooping(true)
      ..setVolume(0)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      }).catchError((_) {
        // 视频解码失败：保持黑底，不影响前景
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const ColoredBox(color: Colors.black);
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: _controller.value.size.width,
        height: _controller.value.size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
