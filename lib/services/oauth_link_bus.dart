import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// OAuth 深链总线
///
/// 解决两个问题：
/// 1. App 被系统回收后由深链冷启动时，`uriLinkStream` 不会补发初始链接；
/// 2. GitHub / Gitee 两套授权流程需要共享同一条深链监听，避免重复订阅。
///
/// 统一在 `main()` 中初始化一次，授权流程通过 [waitFor] 等待匹配的回调。
class OAuthLinkBus {
  OAuthLinkBus._();

  static final OAuthLinkBus instance = OAuthLinkBus._();

  final AppLinks _appLinks = AppLinks();
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  StreamSubscription<Uri>? _subscription;
  Uri? _lastLink;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// App Links 深链流；除 OAuth 外也供插件安装等动作订阅。
  Stream<Uri> get linkStream => _controller.stream;

  /// 最近一次收到的深链（可能来自冷启动，也可能是上一次授权遗留）
  Uri? get lastLink => _lastLink;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _remember(initial);
    } catch (e) {
      debugPrint('读取初始深链失败：$e');
    }

    try {
      _subscription = _appLinks.uriLinkStream.listen(
        _remember,
        onError: (Object e) => debugPrint('深链监听异常：$e'),
      );
    } catch (e) {
      debugPrint('订阅深链失败：$e');
    }
  }

  void _remember(Uri uri) {
    // 只缓存本应用的 OAuth 回调 scheme
    if (uri.scheme != 'slipe' && uri.scheme != 'slipecode') return;
    _lastLink = uri;
    if (!_controller.isClosed) _controller.add(uri);
  }

  /// 等待一条满足 [matches] 的深链。
  ///
  /// 优先复用已缓存的链接（冷启动场景），否则等待新的深链事件。
  Future<Uri> waitFor(
    bool Function(Uri uri) matches, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final cached = _lastLink;
    if (cached != null && matches(cached)) return cached;

    try {
      return await _controller.stream
          .firstWhere(matches)
          .timeout(timeout);
    } on TimeoutException {
      throw StateError('未收到授权回调。请在浏览器中点击「打开 SLIPE」，或返回 App 后重试');
    }
  }

  /// 消费掉一条已处理的链接，避免下次授权误用旧 state
  void consume(Uri uri) {
    if (identical(_lastLink, uri) || _lastLink == uri) {
      _lastLink = null;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
    _initialized = false;
  }
}
