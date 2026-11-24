import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';

import '../../l10n/app_localizations.dart';
import '../../services/app_globals.dart';
import '../../services/crash_log_service.dart';
import '../../services/desktop_platform.dart';
import '../../services/desktop_prefs_service.dart';
import '../../services/hub_bridge_service.dart';
import '../../services/launch_args.dart';

/// 桌面窗口生命周期：初始尺寸、最小尺寸、位置恢复、关闭确认。
class DesktopWindowHost {
  DesktopWindowHost._();

  static final DesktopWindowHost instance = DesktopWindowHost._();

  static const Size minimumWindowSize = Size(1024, 680);
  static const Size defaultWindowSize = Size(1440, 900);

  bool _initialized = false;
  DesktopPrefsService? _prefs;
  final _WindowListener _listener = _WindowListener();
  Timer? _placementTimer;

  /// 是否持久化窗口几何（Hub 保存；Editor 子进程窗口不写，避免互相覆盖）
  bool _persistPlacement = true;

  /// 是否有未保存修改（由 main.dart 注入）。
  bool Function()? hasUnsavedChanges;

  /// 保存全部文件，返回是否全部成功。
  Future<bool> Function()? saveAll;

  bool get isInitialized => _initialized;

  Future<void> initialize(
    DesktopPrefsService prefs, {
    String title = 'SLIPE',
    bool persistPlacement = true,
    Size? preferredSize,
    bool center = false,
  }) async {
    if (!DesktopPlatform.isDesktop || _initialized) return;
    _initialized = true;
    _prefs = prefs;
    _persistPlacement = persistPlacement;
    try {
      await windowManager.ensureInitialized();
      // 上次退出时是最大化：用默认尺寸建窗，随后再最大化。
      // 直接用保存的「最大化尺寸」建窗会导致窗口超出屏幕。
      final restoreMaximized = persistPlacement && prefs.windowMaximized;
      var size =
          preferredSize ??
          (restoreMaximized
              ? defaultWindowSize
              : Size(
                  prefs.windowWidth <= 0
                      ? defaultWindowSize.width
                      : prefs.windowWidth,
                  prefs.windowHeight <= 0
                      ? defaultWindowSize.height
                      : prefs.windowHeight,
                ));
      // 兜底：历史几何可能超过当前屏幕（换过显示器 / DPI 变化），
      // 超出屏幕的窗口会让整窗软件渲染变得极慢，直接回退到默认尺寸
      final display = _displayLogicalSize();
      if (display != null &&
          (size.width > display.width || size.height > display.height)) {
        size = defaultWindowSize;
      }
      await windowManager.setPreventClose(true);
      await windowManager.waitUntilReadyToShow(
        WindowOptions(
          size: size,
          minimumSize: minimumWindowSize,
          center: center || !persistPlacement || !prefs.hasWindowPlacement,
          title: title,
          backgroundColor: Colors.transparent,
          skipTaskbar: false,
          titleBarStyle: TitleBarStyle.hidden,
        ),
        () async {
          // 先显示再还原最大化：Wayland / 部分窗口管理器在窗口尚未映射时
          // 计算最大化尺寸会得到超出屏幕的几何（导致整屏渲染极慢）
          if (persistPlacement &&
              prefs.hasWindowPlacement &&
              !prefs.windowMaximized &&
              !_isWayland) {
            await windowManager.setPosition(
              Offset(prefs.windowX, prefs.windowY),
            );
          }
          await windowManager.show();
          await windowManager.focus();
          if (persistPlacement && prefs.windowMaximized) {
            await windowManager.maximize();
          }
          // 不要在窗口映射后再 setSize / setPosition：
          // Wayland（KWin）下这些调用只会改变客户端缓冲尺寸，不会同步
          // xdg_toplevel 的窗口几何，于是「绘制区域」比「输入区域」大，
          // 窗口右侧/底部点击会直接穿透到下层窗口（表现为点击像落在窗口外、
          // 标题栏失去焦点）。初始尺寸由 WindowOptions 交给合成器决定即可。
        },
      );
      windowManager.addListener(_listener);
      // 诊断：记录窗口实际几何，便于排查「视图尺寸 / 窗口尺寸 / 屏幕尺寸」不一致
      try {
        final actualSize = await windowManager.getSize();
        final actualPos = await windowManager.getPosition();
        CrashLogService.instance.write(
          'INFO',
          '窗口几何：${actualSize.width.toStringAsFixed(0)}x'
          '${actualSize.height.toStringAsFixed(0)} '
          '@${actualPos.dx.toStringAsFixed(0)},${actualPos.dy.toStringAsFixed(0)} '
          '请求=${size.width.toStringAsFixed(0)}x'
          '${size.height.toStringAsFixed(0)} 居中=$center',
        );
      } catch (_) {}
    } catch (e) {
      debugPrint('桌面窗口初始化失败：$e');
    }
  }

  /// 当前会话是否运行在 Wayland 合成器上
  ///
  /// Wayland 不允许客户端自行定位/改尺寸：相关调用只会改变客户端缓冲，
  /// 不会同步窗口几何，进而造成输入区域与绘制区域错位。
  bool get _isWayland {
    final session = Platform.environment['XDG_SESSION_TYPE'] ?? '';
    if (session.toLowerCase() == 'wayland') return true;
    return (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
  }

  /// 当前主显示器的逻辑尺寸（拿不到时返回 null）
  Size? _displayLogicalSize() {
    try {
      final displays = WidgetsBinding.instance.platformDispatcher.displays;
      if (displays.isEmpty) return null;
      final display = displays.first;
      final ratio = display.devicePixelRatio <= 0
          ? 1.0
          : display.devicePixelRatio;
      return Size(display.size.width / ratio, display.size.height / ratio);
    } catch (_) {
      return null;
    }
  }

  void _schedulePlacementSave() {
    if (!_persistPlacement) return;
    _placementTimer?.cancel();
    _placementTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(persistPlacement());
    });
  }

  Future<void> persistPlacement() async {
    final prefs = _prefs;
    if (!_persistPlacement) return;
    if (prefs == null || !_initialized) return;
    try {
      final maximized = await windowManager.isMaximized();
      // 最大化状态下不要把「最大化尺寸」写成窗口尺寸：
      // 下次启动按该尺寸建窗再最大化，会得到超出屏幕的几何（Wayland 下尤其明显）
      final size = maximized ? null : await windowManager.getSize();
      final position = maximized ? null : await windowManager.getPosition();
      prefs.update(() {
        if (size != null) {
          prefs.windowWidth = size.width;
          prefs.windowHeight = size.height;
        }
        if (position != null) {
          prefs.windowX = position.dx;
          prefs.windowY = position.dy;
        }
        prefs.windowMaximized = maximized;
        prefs.hasWindowPlacement = true;
      });
      await prefs.save();
    } catch (e) {
      debugPrint('保存窗口位置失败：$e');
    }
  }

  /// 把窗口重新显示并聚焦（Hub 被隐藏后由 Editor 唤醒）
  Future<void> showWindow() async {
    if (!_initialized) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('显示窗口失败：$e');
    }
  }

  Future<void> requestClose() async {
    if (!await confirmUnsavedChanges()) return;
    await persistPlacement();
    // 窗口互斥：Editor 关闭前先恢复/拉起 Hub，避免 Hub 隐藏后应用「消失」
    if (LaunchArgs.isEditor && DesktopPlatform.isDesktop) {
      await HubBridgeService.instance.showOrLaunchHub();
    }
    if (LaunchArgs.isHub) {
      await HubBridgeService.instance.stopHubListener();
    }
    await windowManager.destroy();
  }

  /// 关闭窗口但不恢复 Hub。
  ///
  /// 用于编辑器直接切换到另一个项目：新项目窗口已经拉起，
  /// 此时销毁旧窗口不应再弹出 Hub。
  Future<void> destroyWithoutHub() async {
    await persistPlacement();
    await windowManager.destroy();
  }

  /// 未保存改动的确认流程：返回 true 表示可以继续关闭/切换
  Future<bool> confirmUnsavedChanges() async {
    final context = appNavigatorKey.currentContext;
    if (hasUnsavedChanges?.call() != true || context == null) return true;
    final action = await showDialog<_CloseAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('desktop.closeTitle')),
        content: Text(t('desktop.closeBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t('common.cancel')),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CloseAction.discard),
            child: Text(t('desktop.closeDiscard')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CloseAction.saveAndQuit),
            child: Text(t('desktop.closeSaveAndQuit')),
          ),
        ],
      ),
    );
    if (action == null) return false;
    if (action == _CloseAction.saveAndQuit) {
      final saved = await saveAll?.call() ?? true;
      if (!saved) return false;
    }
    return true;
  }

  Future<void> dispose() async {
    _placementTimer?.cancel();
    if (_initialized) {
      try {
        windowManager.removeListener(_listener);
      } catch (_) {}
    }
  }
}

enum _CloseAction { saveAndQuit, discard }

class _WindowListener extends WindowListener {
  @override
  void onWindowClose() {
    unawaited(DesktopWindowHost.instance.requestClose());
  }

  @override
  void onWindowMoved() {
    DesktopWindowHost.instance._schedulePlacementSave();
  }

  @override
  void onWindowResized() {
    DesktopWindowHost.instance._schedulePlacementSave();
  }

  @override
  void onWindowMaximize() {
    DesktopWindowHost.instance._schedulePlacementSave();
  }

  @override
  void onWindowUnmaximize() {
    DesktopWindowHost.instance._schedulePlacementSave();
  }
}
