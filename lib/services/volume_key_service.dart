import 'package:flutter/services.dart';

/// 音量键拦截服务（仅 Android）
///
/// Flutter 侧通过 [setHandler] 注册一个处理器：
/// - 返回 true  表示消费掉这次按键（系统不再调节音量）
/// - 返回 false 表示放行（系统正常调节音量）
///
/// 不注册或传入 null 时，音量键保持系统默认行为。
/// iOS 不支持音量键拦截，所有调用为空操作。
class VolumeKeyService {
  VolumeKeyService._() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static final VolumeKeyService instance = VolumeKeyService._();

  static const _channel = MethodChannel('slipe/keyevent');

  /// Android KeyEvent.KEYCODE_VOLUME_UP / DOWN
  static const int keyVolumeUp = 24;
  static const int keyVolumeDown = 25;

  /// 当前注册的处理器（返回是否消费该按键）
  bool Function(int keyCode)? _handler;

  /// 是否已启用拦截
  bool get isEnabled => _handler != null;

  /// 注册/注销音量键处理器
  ///
  /// [handler] 为 null 时注销，音量键恢复系统默认行为。
  Future<void> setHandler(bool Function(int keyCode)? handler) async {
    _handler = handler;
    try {
      await _channel.invokeMethod('setVolumeKeyListener', {
        'enabled': handler != null,
      });
    } catch (_) {
      // 平台不支持（如 iOS）时静默失败
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onVolumeKey') {
      final keyCode = call.arguments as int? ?? 0;
      final handler = _handler;
      if (handler == null) return false;
      try {
        return handler(keyCode);
      } catch (_) {
        return false;
      }
    }
    return null;
  }
}
