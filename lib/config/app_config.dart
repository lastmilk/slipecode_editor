import 'package:flutter_dotenv/flutter_dotenv.dart';

/// 应用配置
///
/// 从 .env 读取 GitHub OAuth 配置。
/// 客户端不内置任何 client secret —— 授权采用 PKCE，
/// 仅有公开性的 Client ID 需要配置（可以留空，在界面上提示用户配置）。
class AppConfig {
  AppConfig._();

  static String _env(String key, [String fallback = '']) {
    final value = dotenv.env[key];
    if (value == null || value.trim().isEmpty) return fallback;
    return value.trim();
  }

  /// GitHub OAuth App 的 Client ID（公开信息，非 secret）
  static String get githubClientId => _env('GITHUB_CLIENT_ID');

  /// 是否已配置 Client ID
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
}
