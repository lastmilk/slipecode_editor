import 'package:flutter_dotenv/flutter_dotenv.dart';

/// 应用配置
///
/// 从 .env 读取 GitHub / Gitee / 账号后端配置。
/// 客户端不内置任何 client secret：
/// - GitHub 使用 PKCE，只需要公开的 Client ID；
/// - Gitee 原生不支持 PKCE，授权码必须由自建后端用 client_secret 换取 token。
class AppConfig {
  AppConfig._();

  static String _env(String key, [String fallback = '']) {
    final value = dotenv.env[key];
    if (value == null || value.trim().isEmpty) return fallback;
    return value.trim();
  }

  // ---------------------------------------------------------------------------
  // GitHub
  // ---------------------------------------------------------------------------

  /// GitHub OAuth App 的 Client ID（公开信息，非 secret）
  static String get githubClientId => _env('GITHUB_CLIENT_ID');

  /// 是否已配置 GitHub Client ID
  static bool get isConfigured => githubClientId.isNotEmpty;

  /// OAuth 回调地址（深链）
  static String get oauthRedirectUri =>
      _env('GITHUB_OAUTH_REDIRECT_URI', 'slipecode://oauth/callback');

  /// 授权范围
  static String get oauthScopes =>
      _env('GITHUB_OAUTH_SCOPES', 'repo workflow read:user');

  /// GitHub REST API 基础地址
  static String get apiBase => _env('GITHUB_API_BASE', 'https://api.github.com');

  /// GitHub OAuth 授权/换 token 基础地址
  static String get oauthBase =>
      _env('GITHUB_OAUTH_BASE', 'https://github.com/login/oauth');

  // ---------------------------------------------------------------------------
  // Gitee
  // ---------------------------------------------------------------------------

  /// Gitee OAuth 应用 Client ID（凭据在 .env 中留空，配置后即可启用）
  static String get giteeClientId => _env('GITEE_CLIENT_ID');

  /// Gitee OAuth 回调深链
  static String get giteeRedirectUri => _env(
        'GITEE_OAUTH_REDIRECT_URI',
        'slipecode://oauth/gitee/callback',
      );

  /// Gitee 授权范围（projects 用于仓库读写）
  static String get giteeScopes => _env('GITEE_OAUTH_SCOPES', 'projects user_info');

  /// Gitee OpenAPI 基础地址
  static String get giteeApiBase =>
      _env('GITEE_API_BASE', 'https://gitee.com/api/v5');

  /// Gitee OAuth 授权页基础地址
  static String get giteeOauthBase =>
      _env('GITEE_OAUTH_BASE', 'https://gitee.com/oauth');

  /// 是否已配置 Gitee（还必须有账号后端，否则无法换 token）
  static bool get isGiteeConfigured =>
      giteeClientId.isNotEmpty && accountBackendBase.isNotEmpty;

  // ---------------------------------------------------------------------------
  // 账号后端（同时作为 Gitee OAuth 的 token 代理）
  // ---------------------------------------------------------------------------

  /// 自建账号后端地址，例如 https://api.example.com
  static String get accountBackendBase =>
      _env('ACCOUNT_BACKEND_BASE_URL').replaceAll(RegExp(r'/+$'), '');

  /// 是否已配置账号后端
  static bool get isAccountBackendConfigured => accountBackendBase.isNotEmpty;

  /// Gitee 授权码换取 token 的后端接口
  static String get giteeTokenEndpoint => accountBackendBase.isEmpty
      ? ''
      : '$accountBackendBase/api/oauth/gitee/token';

  /// Gitee refresh_token 续期接口
  static String get giteeRefreshEndpoint => accountBackendBase.isEmpty
      ? ''
      : '$accountBackendBase/api/oauth/gitee/refresh';
}
