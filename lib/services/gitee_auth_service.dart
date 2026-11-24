import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import 'desktop_oauth_prompt.dart';
import 'desktop_platform.dart';
import 'github_auth_service.dart' show HttpExceptionWithBody;
import 'oauth_link_bus.dart';

/// Gitee 授权结果
class GiteeAuthResult {
  final String accessToken;
  final String? refreshToken;
  final String scope;
  final DateTime? expiresAt;

  const GiteeAuthResult({
    required this.accessToken,
    this.refreshToken,
    required this.scope,
    this.expiresAt,
  });
}

/// Gitee OAuth 授权服务
///
/// Gitee 原生不支持 PKCE，客户端无法安全保存 client_secret，
/// 因此授权码统一发送到自建后端（ACCOUNT_BACKEND_BASE_URL）换取 token。
/// Gitee 的 access_token 有效期约 1 天，过期前可用 refresh_token 续期。
class GiteeAuthService {
  GiteeAuthService._();

  static final GiteeAuthService instance = GiteeAuthService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenKey = 'gitee_access_token';
  static const _refreshKey = 'gitee_refresh_token';
  static const _expiryKey = 'gitee_token_expiry';
  static const _scopeKey = 'gitee_token_scope';

  Completer<Uri>? _cancel;

  Future<String?> get savedToken => _storage.read(key: _tokenKey);

  Future<String?> get savedRefreshToken => _storage.read(key: _refreshKey);

  Future<DateTime?> get savedExpiry async {
    final raw = await _storage.read(key: _expiryKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<String?> get savedScope => _storage.read(key: _scopeKey);

  /// 读取 token；临近过期时自动续期
  Future<String?> validToken() async {
    final token = await savedToken;
    if (token == null || token.isEmpty) return null;
    final expiry = await savedExpiry;
    if (expiry == null || expiry.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return token;
    }
    final refreshed = await _refresh();
    return refreshed ?? token;
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _expiryKey);
    await _storage.delete(key: _scopeKey);
  }

  String _randomString(int length) {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  // ---------------------------------------------------------------------------
  // 授权流程
  // ---------------------------------------------------------------------------

  /// 发起授权：打开浏览器 → 深链回调拿到 code → 后端换 token。
  Future<GiteeAuthResult> signIn({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (AppConfig.giteeClientId.isEmpty) {
      throw StateError('未配置 GITEE_CLIENT_ID，请先在 .env 中填写');
    }
    if (AppConfig.giteeTokenEndpoint.isEmpty) {
      throw StateError(
        '未配置账号后端（ACCOUNT_BACKEND_BASE_URL）。Gitee 不支持 PKCE，'
        '必须通过后端用 client_secret 换取 token',
      );
    }

    final state = _randomString(32);
    final authorizeUri = Uri.parse('${AppConfig.giteeOauthBase}/authorize')
        .replace(queryParameters: {
      'client_id': AppConfig.giteeClientId,
      'redirect_uri': AppConfig.giteeRedirectUri,
      'response_type': 'code',
      'scope': AppConfig.giteeScopes,
      'state': state,
    });

    final cancel = Completer<Uri>();
    _cancel = cancel;
    try {
      // 桌面端没有移动深链：外部浏览器授权后由用户粘贴回调地址
      if (DesktopPlatform.isDesktop) {
        final launched = await launchUrl(
          authorizeUri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          throw StateError('无法打开浏览器完成 Gitee 授权');
        }
        final pasted = await DesktopOAuthPrompt.ask(
          hint: 'slipe://oauth/gitee/callback',
        );
        if (pasted == null) throw StateError('已取消授权');
        if (!_isCallbackUri(pasted)) {
          throw StateError('回调地址与预期不符，请复制完整链接后重试');
        }
        return await _finishSignIn(pasted, state);
      }

      final launched = await launchUrl(
        authorizeUri,
        // 同 GitHub：用应用内浏览器视图，避免第三方浏览器/App 拦截导致 404
        mode: LaunchMode.inAppBrowserView,
      );
      if (!launched) {
        throw StateError('无法打开浏览器完成 Gitee 授权');
      }

      final callback = await Future.any<Uri>([
        OAuthLinkBus.instance.waitFor(
          (uri) =>
              _isCallbackUri(uri) && uri.queryParameters['state'] == state,
          timeout: timeout,
        ),
        cancel.future,
      ]);
      OAuthLinkBus.instance.consume(callback);

      return await _finishSignIn(callback, state);
    } finally {
      if (!cancel.isCompleted) {
        cancel.completeError(StateError('已取消授权'));
      }
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  /// 校验回调并换取 token（移动端深链 / 桌面粘贴共用）
  Future<GiteeAuthResult> _finishSignIn(Uri callback, String state) async {
    if (callback.queryParameters['state'] != state) {
      throw StateError('Gitee 授权回调 state 校验失败');
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      throw StateError(
        'Gitee 授权被拒绝：$error ${callback.queryParameters['error_description'] ?? ''}',
      );
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw StateError('Gitee 授权回调缺少 code');
    }

    final result = await _exchangeCode(code);
    await _save(result);
    return result;
  }

  bool _isCallbackUri(Uri uri) {
    // Gitee 回调先到后端桥接页，再由桥接页跳到 App 的固定深链；
    // 该深链与 OAuth 的 redirect_uri（https 地址）是两回事。
    const expected = 'slipe://oauth/gitee/callback';
    final target = Uri.parse(expected);
    if (uri.scheme == target.scheme &&
        uri.host == target.host &&
        uri.path == target.path) {
      return true;
    }
    // 兼容旧 scheme：slipecode://oauth/gitee/callback
    return uri.scheme == 'slipecode' &&
        uri.host == 'oauth' &&
        uri.path == '/gitee/callback';
  }

  /// 取消正在进行的授权
  Future<void> cancelSignIn() async {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) {
      cancel.completeError(StateError('已取消授权'));
    }
  }

  // ---------------------------------------------------------------------------
  // 后端换 token / 续期
  // ---------------------------------------------------------------------------

  Future<GiteeAuthResult> _exchangeCode(String code) async {
    final res = await http
        .post(
          Uri.parse(AppConfig.giteeTokenEndpoint),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'code': code,
            'redirect_uri': AppConfig.giteeRedirectUri,
          }),
        )
        .timeout(const Duration(seconds: 20));

    final data = _decodeOrThrow(res, 'Gitee 换取 token 失败');
    return _parseResult(data);
  }

  Future<String?> _refresh() async {
    final endpoint = AppConfig.giteeRefreshEndpoint;
    final refreshToken = await savedRefreshToken;
    if (endpoint.isEmpty || refreshToken == null || refreshToken.isEmpty) {
      return null;
    }
    try {
      final res = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 20));
      final data = _decodeOrThrow(res, 'Gitee token 续期失败');
      final result = _parseResult(data);
      await _save(result);
      return result.accessToken;
    } catch (e) {
      debugPrint('Gitee token 续期失败：$e');
      return null;
    }
  }

  Map<String, dynamic> _decodeOrThrow(http.Response res, String what) {
    Map<String, dynamic> data = {};
    try {
      if (res.body.isNotEmpty) {
        data = jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final detail = (data['error_description'] ??
              data['message'] ??
              data['error'] ??
              '')
          .toString();
      throw HttpExceptionWithBody(
        '$what（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
        res.body,
      );
    }
    return data;
  }

  GiteeAuthResult _parseResult(Map<String, dynamic> data) {
    // 兼容后端直接透传或包一层 data 的返回
    final payload = data['data'] is Map<String, dynamic>
        ? data['data'] as Map<String, dynamic>
        : data;
    final accessToken = payload['access_token'] as String? ?? '';
    if (accessToken.isEmpty) {
      throw HttpExceptionWithBody(
        'Gitee 未返回 access_token',
        jsonEncode(data),
      );
    }
    final expiresIn = payload['expires_in'];
    return GiteeAuthResult(
      accessToken: accessToken,
      refreshToken: payload['refresh_token'] as String?,
      scope: payload['scope'] as String? ?? '',
      expiresAt: expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }

  Future<void> _save(GiteeAuthResult result) async {
    await _storage.write(key: _tokenKey, value: result.accessToken);
    await _storage.write(key: _scopeKey, value: result.scope);
    if (result.refreshToken != null && result.refreshToken!.isNotEmpty) {
      await _storage.write(key: _refreshKey, value: result.refreshToken);
    }
    if (result.expiresAt != null) {
      await _storage.write(
        key: _expiryKey,
        value: result.expiresAt!.toIso8601String(),
      );
    }
  }
}
