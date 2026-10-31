import 'dart:async';
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

  /// 页面背景媒体需要感知路由切换：被其它页面遮挡时暂停，返回时恢复，
  /// 避免多个 VideoPlayer 同时解码导致偶发暂停。
  static final RouteObserver<PageRoute<dynamic>> routeObserver =
      RouteObserver<PageRoute<dynamic>>();

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
            child: _WallpaperMedia(key: ValueKey(path), path: path),
          ),
        ),
        child,
      ],
    );
  }
}

/// 动态壁纸（MP4 / GIF）：处理路由遮挡与 App 前后台切换导致的暂停
class _WallpaperMedia extends StatefulWidget {
  const _WallpaperMedia({super.key, required this.path});

  final String path;

  @override
  State<_WallpaperMedia> createState() => _WallpaperMediaState();
}

class _WallpaperMediaState extends State<_WallpaperMedia>
    with WidgetsBindingObserver, RouteAware {
  VideoPlayerController? _controller;
  Timer? _watchdog;
  PageRoute<dynamic>? _route;
  bool _ready = false;
  bool _visible = true;

  bool get _isVideo => AppBackground.isVideoPath(widget.path);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isVideo) {
      _initVideo();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) {
        AppBackground.routeObserver.unsubscribe(this);
      }
      _route = route;
      AppBackground.routeObserver.subscribe(this, route);
    }
  }

  Future<void> _initVideo() async {
    final controller = VideoPlayerController.file(File(widget.path));
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      await controller.setLooping(true);
      await controller.setVolume(0);
      setState(() => _ready = true);
      _playIfVisible();
      // 看门狗：系统回收资源或解码器空闲时自动恢复播放
      _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted || !_visible) return;
        final value = _controller?.value;
        if (value == null || !value.isInitialized) return;
        if (!value.isPlaying && !value.isCompleted) {
          _controller?.play();
        }
      });
    } catch (_) {
      // 视频解码失败：保持黑底，不影响前景
      if (mounted) setState(() => _ready = false);
    }
  }

  void _playIfVisible() {
    if (!mounted || !_visible) return;
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (!controller.value.isPlaying) controller.play();
  }

  @override
  void didPushNext() {
    _visible = false;
    _controller?.pause();
  }

  @override
  void didPopNext() {
    _visible = true;
    _playIfVisible();
    // 触发一次重建，让 GIF 动画重新调度
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _visible = true;
        _playIfVisible();
        if (mounted) setState(() {});
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _visible = false;
        _controller?.pause();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_route != null) {
      AppBackground.routeObserver.unsubscribe(this);
    }
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVideo) {
      return TickerMode(
        enabled: _visible,
        child: Image.file(
          File(widget.path),
          key: ValueKey(widget.path),
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }

    final controller = _controller;
    if (!_ready || controller == null) {
      return const ColoredBox(color: Colors.black);
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}
