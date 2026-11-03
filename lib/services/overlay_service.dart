import 'package:flutter/services.dart';

/// 系统悬浮球点击「执行」后携带的请求
class OverlayAiRequest {
  const OverlayAiRequest({this.prompt, this.projectPath});

  final String? prompt;
  final String? projectPath;

  factory OverlayAiRequest.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const OverlayAiRequest();
    return OverlayAiRequest(
      prompt: map['prompt'] as String?,
      projectPath: map['project'] as String?,
    );
  }
}

/// 系统悬浮窗（AI 悬浮球）服务
///
/// Android：通过 SYSTEM_ALERT_WINDOW 权限 + 前台服务显示一个可拖拽悬浮球，
/// 点击后弹出轻量 AI 输入面板。iOS 不支持系统悬浮窗，所有方法返回 null/false。
class OverlayService {
  OverlayService._();

  static final OverlayService instance = OverlayService._();

  static const _channel = MethodChannel('slipe/overlay');

  bool _initialized = false;

  /// 初始化悬浮球事件监听。
  ///
  /// [onOpenAiChat] 在用户点击系统悬浮球（或在其轻量面板中提交需求）时触发：
  /// 直接弹出轻量 AI 对话窗，而不是跳转到 App 主界面。
  Future<void> init({
    required void Function(OverlayAiRequest request) onOpenAiChat,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openAiChat') {
        onOpenAiChat(OverlayAiRequest.fromMap(call.arguments as Map?));
      }
      return null;
    });
    // 冷启动：Activity onCreate 时携带的请求在 Dart 就绪后只消费一次
    try {
      final pending = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
        'consumeOpenAiChat',
      );
      if (pending != null && pending['open'] == true) {
        onOpenAiChat(OverlayAiRequest.fromMap(pending));
      }
    } catch (_) {
      // 平台不支持时忽略
    }
  }

  /// 是否拥有「显示在其他应用上层」权限（iOS 恒为 false）
  Future<bool> checkPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到系统设置页请求悬浮窗权限
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 显示悬浮球
  Future<bool> show() async {
    try {
      return await _channel.invokeMethod<bool>('showOverlay') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 隐藏悬浮球
  Future<bool> hide() async {
    try {
      return await _channel.invokeMethod<bool>('hideOverlay') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 悬浮球当前是否显示中
  Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isOverlayShowing') ?? false;
    } catch (_) {
      return false;
    }
  }
}
