import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import 'oauth_link_bus.dart';

/// GitHub OAuth 授权结果
class GitHubAuthResult {
  final String accessToken;
  final String scope;
  final String tokenType;

  const GitHubAuthResult({
    required this.accessToken,
    required this.scope,
    required this.tokenType,
  });
}

/// GitHub OAuth 授权服务（后端换取 token）
///
/// 客户端不保存 client secret：
/// 授权页只带 client_id 和 state；回调拿到 code 后交给自建后端，
/// 由后端用 client_secret 换取 access_token（与 Gitee 同一套原理）。
class GitHubAuthService {
  GitHubAuthService._();

  static final GitHubAuthService instance = GitHubAuthService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenKey = 'github_access_token';
  static const _scopeKey = 'github_token_scope';

  Completer<Uri>? _cancel;

  /// 读取已保存的 token
  Future<String?> get savedToken => _storage.read(key: _tokenKey);

  /// 读取已保存 token 的授权范围
  Future<String?> get savedScope => _storage.read(key: _scopeKey);

  /// 清除已保存的 token
  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _scopeKey);
  }

  String _randomState() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  // ---------------------------------------------------------------------------
  // 授权流程
  // ---------------------------------------------------------------------------

  /// 发起授权：打开浏览器并等待深链回调，完成后由后端换取并保存 token。
  ///
  /// 必须在 UI 主 Isolate 中调用。超时时间 [timeout] 默认 5 分钟。
  Future<GitHubAuthResult> signIn({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final clientId = AppConfig.githubClientId;
    if (clientId.isEmpty) {
      throw StateError('未配置 GITHUB_CLIENT_ID，请先在 .env 中填写');
    }
    if (AppConfig.githubTokenEndpoint.isEmpty) {
      throw StateError('未配置账号后端，GitHub 授权需要后端换取 token');
    }

    final state = _randomState();

    final authorizeUri = Uri.parse('${AppConfig.oauthBase}/authorize')
        .replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': AppConfig.oauthRedirectUri,
        'scope': AppConfig.oauthScopes,
        'state': state,
        'allow_signup': 'true',
      },
    );

    final cancel = Completer<Uri>();
    _cancel = cancel;
    try {
      final launched = await launchUrl(
        authorizeUri,
        // 用 Custom Tab / SFSafariViewController 打开，避免被 GitHub App
        // 等已注册 github.com 链接的应用拦截（拦截后授权页会显示 404）
        mode: LaunchMode.inAppBrowserView,
      );
      if (!launched) {
        throw StateError('无法打开浏览器完成授权');
      }

      // 深链总线会优先复用冷启动时的 initial link，再等待新的回调事件；
      // 同时与取消信号赛跑，保证用户点「取消」能立即结束等待。
      final callback = await Future.any<Uri>([
        OAuthLinkBus.instance.waitFor(
          (uri) =>
              _isCallbackUri(uri) && uri.queryParameters['state'] == state,
          timeout: timeout,
        ),
        cancel.future,
      ]);
      OAuthLinkBus.instance.consume(callback);

      // 校验 state 防 CSRF
      if (callback.queryParameters['state'] != state) {
        throw StateError('授权回调 state 校验失败');
      }
      final error = callback.queryParameters['error'];
      if (error != null) {
        throw StateError(
          '授权被拒绝：$error ${callback.queryParameters['error_description'] ?? ''}',
        );
      }

      // 后端中转回调会带回一次性 ticket（token 已由后端换好），
      // 直接深链回调则带回 code，两种情况都交给后端接口。
      final ticket = callback.queryParameters['ticket'];
      final code = callback.queryParameters['code'];
      if ((ticket ?? '').isEmpty && (code ?? '').isEmpty) {
        throw StateError('授权回调缺少 code / ticket');
      }

      final result = await _exchange(ticket: ticket, code: code);
      await _storage.write(key: _tokenKey, value: result.accessToken);
      await _storage.write(key: _scopeKey, value: result.scope);
      return result;
    } finally {
      if (!cancel.isCompleted) {
        cancel.completeError(StateError('已取消授权'));
      }
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  bool _isCallbackUri(Uri uri) {
    final expected = Uri.parse(AppConfig.oauthDeepLink);
    if (uri.scheme == expected.scheme &&
        uri.host == expected.host &&
        uri.path == expected.path) {
      return true;
    }
    // 兼容线上旧配置：slipecode://oauth/callback
    return uri.scheme == 'slipecode' &&
        uri.host == 'oauth' &&
        uri.path == '/callback';
  }

  /// 取消正在进行的授权
  Future<void> cancelSignIn() async {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) {
      cancel.completeError(StateError('已取消授权'));
    }
  }

  /// 把授权结果交给自建后端：由后端用 client_secret 换取 / 领取 access token
  Future<GitHubAuthResult> _exchange({
    String? ticket,
    String? code,
  }) async {
    final body = (ticket ?? '').isNotEmpty
        ? {'ticket': ticket}
        : {'code': code, 'redirect_uri': AppConfig.oauthRedirectUri};

    final response = await http
        .post(
          Uri.parse(AppConfig.githubTokenEndpoint),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw HttpExceptionWithBody(
        '后端换取 GitHub token 失败（HTTP ${response.statusCode}）',
        response.body,
      );
    }

    final decoded = jsonDecode(response.body);
    // 后端可能直接返回，也可能包一层 data
    final data = decoded is Map<String, dynamic>
        ? (decoded['data'] is Map<String, dynamic>
            ? decoded['data'] as Map<String, dynamic>
            : decoded)
        : <String, dynamic>{};

    if (data['error'] != null) {
      throw HttpExceptionWithBody(
        '换取 token 失败：${data['error_description'] ?? data['error']}',
        response.body,
      );
    }
    final token = data['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw HttpExceptionWithBody('后端未返回 access_token', response.body);
    }

    return GitHubAuthResult(
      accessToken: token,
      scope: data['scope'] as String? ?? '',
      tokenType: data['token_type'] as String? ?? 'bearer',
    );
  }
}

/// 带响应体的 HTTP 异常，便于展示 GitHub 返回的具体错误
class HttpExceptionWithBody implements Exception {
  final String message;
  final String body;

  const HttpExceptionWithBody(this.message, this.body);

  @override
  String toString() {
    debugPrint('GitHub HTTP error body: $body');
    return message;
  }
}
