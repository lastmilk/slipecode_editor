import 'package:flutter/services.dart';

/// 系统悬浮窗（AI 悬浮球）服务
///
/// Android：通过 SYSTEM_ALERT_WINDOW 权限 + 前台服务显示一个可拖拽悬浮球，
/// 点击后回到 App。iOS 不支持系统悬浮窗，所有方法返回 null/false。
class OverlayService {
  OverlayService._();

  static final OverlayService instance = OverlayService._();

  static const _channel = MethodChannel('slipe/overlay');

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
