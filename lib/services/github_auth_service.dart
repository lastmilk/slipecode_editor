import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

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

/// GitHub OAuth 授权服务（PKCE）
///
/// 客户端不保存 client secret：
/// 授权码交换时通过 code_verifier 证明身份（RFC 7636）。
class GitHubAuthService {
  GitHubAuthService._();

  static final GitHubAuthService instance = GitHubAuthService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenKey = 'github_access_token';
  static const _scopeKey = 'github_token_scope';

  final AppLinks _appLinks = AppLinks();
  Completer<Uri>? _pendingCallback;
  StreamSubscription<Uri>? _linkSub;

  /// 读取已保存的 token
  Future<String?> get savedToken => _storage.read(key: _tokenKey);

  /// 读取已保存 token 的授权范围
  Future<String?> get savedScope => _storage.read(key: _scopeKey);

  /// 清除已保存的 token
  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _scopeKey);
  }

  // ---------------------------------------------------------------------------
  // PKCE
  // ---------------------------------------------------------------------------

  String _randomString(int length) {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  // ---------------------------------------------------------------------------
  // 授权流程
  // ---------------------------------------------------------------------------

  /// 发起授权：打开浏览器并等待深链回调，完成后换取并保存 token。
  ///
  /// 必须在 UI 主 Isolate 中调用。超时时间 [timeout] 默认 5 分钟。
  Future<GitHubAuthResult> signIn({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final clientId = AppConfig.githubClientId;
    if (clientId.isEmpty) {
      throw StateError('未配置 GITHUB_CLIENT_ID，请先在 .env 中填写');
    }

    final state = _randomString(32);
    final verifier = _randomString(64);
    final challenge = _codeChallenge(verifier);

    final authorizeUri =
        Uri.parse('${AppConfig.oauthBase}/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': AppConfig.oauthRedirectUri,
        'scope': AppConfig.oauthScopes,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );

    // 先订阅深链，再打开浏览器，避免竞态
    _pendingCallback = Completer<Uri>();
    await _linkSub?.cancel();
    _linkSub = _appLinks.uriLinkStream.listen((uri) {
      if (_isCallbackUri(uri) && _pendingCallback?.isCompleted == false) {
        _pendingCallback!.complete(uri);
      }
    });

    final launched = await launchUrl(
      authorizeUri,
      // 用 Custom Tab / SFSafariViewController 打开，避免被 GitHub App
      // 等已注册 github.com 链接的应用拦截（拦截后授权页会显示 404）
      mode: LaunchMode.inAppBrowserView,
    );
    if (!launched) {
      await _cleanup();
      throw StateError('无法打开浏览器完成授权');
    }

    final callback = await _pendingCallback!.future
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('授权超时，请重试');
    });
    await _cleanup();

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
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw StateError('授权回调缺少 code');
    }

    final result = await _exchangeCode(code, verifier);
    await _storage.write(key: _tokenKey, value: result.accessToken);
    await _storage.write(key: _scopeKey, value: result.scope);
    return result;
  }

  bool _isCallbackUri(Uri uri) {
    final expected = Uri.parse(AppConfig.oauthRedirectUri);
    return uri.scheme == expected.scheme &&
        uri.host == expected.host &&
        uri.path == expected.path;
  }

  Future<void> _cleanup() async {
    await _linkSub?.cancel();
    _linkSub = null;
    _pendingCallback = null;
  }

  /// 取消正在进行的授权
  Future<void> cancelSignIn() async {
    if (_pendingCallback?.isCompleted == false) {
      _pendingCallback!.completeError(StateError('已取消授权'));
    }
    await _cleanup();
  }

  /// 用授权码 + code_verifier 换 access token（无需 client secret）
  Future<GitHubAuthResult> _exchangeCode(
    String code,
    String codeVerifier,
  ) async {
    final response = await http.post(
      Uri.parse('${AppConfig.oauthBase}/access_token'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': AppConfig.githubClientId,
        'code': code,
        'redirect_uri': AppConfig.oauthRedirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': codeVerifier,
      },
    );

    if (response.statusCode != 200) {
      throw HttpExceptionWithBody(
        '换取 token 失败（HTTP ${response.statusCode}）',
        response.body,
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw HttpExceptionWithBody(
        '换取 token 失败：${data['error_description'] ?? data['error']}',
        response.body,
      );
    }

    return GitHubAuthResult(
      accessToken: data['access_token'] as String,
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
