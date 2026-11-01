import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 构建保活通知（Android 前台服务）
///
/// 构建期间启动前台服务并显示常驻通知，系统会优先保留带常驻通知的进程，
/// 从而在退出构建页 / 退到后台后仍能持续同步构建流程。
/// 非 Android 平台调用会静默失败。
class BuildNotificationService {
  BuildNotificationService._();

  static final BuildNotificationService instance = BuildNotificationService._();

  static const MethodChannel _channel = MethodChannel('slipecode/build_watch');

  bool _running = false;

  bool get isRunning => _running;

  /// 启动前台服务（构建开始时调用）
  Future<void> start(String text) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
      _running = true;
    } catch (e) {
      debugPrint('启动构建保活通知失败：$e');
    }
  }

  /// 更新通知文案（步骤变化时调用）
  Future<void> update(String text) async {
    if (!_running) {
      await start(text);
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('update', {'text': text});
    } catch (e) {
      debugPrint('更新构建保活通知失败：$e');
    }
  }

  /// 停止前台服务（构建结束时调用）
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('停止构建保活通知失败：$e');
    }
  }
}
