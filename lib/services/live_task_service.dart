import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 任务实况通知（类灵动岛）
///
/// 对应 Android 原生 [LiveTaskService]：
/// - Android 16+ 原生 Live Updates（ProgressStyle），ColorOS 等已适配
/// - 小米 HyperOS 焦点通知 / 超级岛
/// - vivo OriginOS 原子通知 / 原子岛
/// - 其余设备退化为可更新的进度通知
///
/// 非 Android 平台静默降级为无操作。
class LiveTaskService {
  LiveTaskService._();

  static final LiveTaskService instance = LiveTaskService._();

  static const MethodChannel _channel = MethodChannel('slipe/live_task');

  /// 用户是否开启实况通知（由设置页写入）
  bool _enabled = true;

  bool get enabled => _enabled;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void configure({required bool enabled}) {
    _enabled = enabled;
    if (!enabled) unawaited(stopAll());
  }

  /// 申请通知权限（仅 Android 13+ 需要，用户拒绝时静默忽略）
  static bool _permissionChecked = false;

  static Future<void> ensurePermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_permissionChecked) return;
    _permissionChecked = true;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) await Permission.notification.request();
    } catch (_) {
      // 前台服务在无通知权限时仍可运行
    }
  }

  /// 开始一个任务通知
  ///
  /// [kind] 为 `ai`（AI 执行）或 `build`（云端构建）；
  /// [progress] 为 0-100，null 表示不确定进度。
  Future<void> start({
    required String id,
    required String kind,
    required String title,
    required String text,
    int? progress,
    bool indeterminate = true,
  }) async {
    if (!_enabled || !_supported) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'id': id,
        'kind': kind,
        'title': title,
        'text': text,
        'progress': progress,
        'indeterminate': indeterminate,
        'done': false,
      });
    } catch (e) {
      debugPrint('开启实况通知失败：$e');
    }
  }

  /// 更新任务进度 / 文案
  Future<void> update({
    required String id,
    required String kind,
    required String title,
    required String text,
    int? progress,
    bool indeterminate = true,
  }) async {
    if (!_enabled || !_supported) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'id': id,
        'kind': kind,
        'title': title,
        'text': text,
        'progress': progress,
        'indeterminate': indeterminate,
        'done': false,
      });
    } catch (e) {
      debugPrint('更新实况通知失败：$e');
    }
  }

  /// 以完成态短暂展示后移除
  Future<void> finish({
    required String id,
    required String kind,
    required String title,
    required String text,
  }) async {
    if (!_enabled || !_supported) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'id': id,
        'kind': kind,
        'title': title,
        'text': text,
        'progress': 100,
        'indeterminate': false,
        'done': true,
      });
      // 完成后保留 2 秒，让用户在岛上看到结束状态
      Timer(const Duration(seconds: 2), () => stop(id));
    } catch (e) {
      debugPrint('完成实况通知失败：$e');
    }
  }

  /// 移除任务通知
  Future<void> stop(String id) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop', {'id': id});
    } catch (e) {
      debugPrint('移除实况通知失败：$e');
    }
  }

  /// 移除全部任务通知
  Future<void> stopAll() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stopAll');
    } catch (e) {
      debugPrint('移除全部实况通知失败：$e');
    }
  }

  /// 查询设备实况通知能力（用于设置页展示适配状态）
  Future<Map<String, dynamic>> capabilities() async {
    if (!_supported) return const {};
    try {
      final result = await _channel.invokeMethod<Map>('capabilities');
      return result == null
          ? const {}
          : result.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return const {};
    }
  }
}
