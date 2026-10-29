import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// SLIPE 账号用户
class AccountUser {
  final String id;
  final String email;
  final String displayName;

  const AccountUser({
    required this.id,
    required this.email,
    required this.displayName,
  });

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
        id: (json['id'] ?? '').toString(),
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ??
            json['display_name'] as String? ??
            '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
      };
}

/// 账号接口异常
class AccountException implements Exception {
  final String message;
  const AccountException(this.message);

  @override
  String toString() => message;
}

/// 自建账号后端客户端
///
/// 后端地址在 .env 的 ACCOUNT_BACKEND_BASE_URL 配置。
/// 接口：register / login / me / settings(GET, PUT)。
class AccountService {
  AccountService._();

  static final AccountService instance = AccountService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _tokenKey = 'slipecode_account_token';

  Future<String?> get savedToken => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  bool get isConfigured => AppConfig.isAccountBackendConfigured;

  Uri _u(String path) => Uri.parse('${AppConfig.accountBackendBase}$path');

  Map<String, String> _headers([String? token]) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Never _fail(http.Response res, String what) {
    String detail = '';
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      detail = (data['error'] ?? data['message'] ?? '').toString();
    } catch (_) {}
    throw AccountException(
      '$what（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
    );
  }

  Future<Map<String, dynamic>> _decode(http.Response res, String what) async {
    if (res.statusCode < 200 || res.statusCode >= 300) _fail(res, what);
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void _ensureConfigured() {
    if (!isConfigured) {
      throw const AccountException(
        '未配置账号后端，请在 .env 中填写 ACCOUNT_BACKEND_BASE_URL',
      );
    }
  }

  /// 注册并直接返回登录态
  Future<(String, AccountUser)> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    _ensureConfigured();
    final res = await http
        .post(
          _u('/api/auth/register'),
          headers: _headers(),
          body: jsonEncode({
            'email': email,
            'password': password,
            'displayName': displayName,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '注册失败');
    return _sessionFrom(data, '注册失败');
  }

  Future<(String, AccountUser)> login({
    required String email,
    required String password,
  }) async {
    _ensureConfigured();
    final res = await http
        .post(
          _u('/api/auth/login'),
          headers: _headers(),
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '登录失败');
    return _sessionFrom(data, '登录失败');
  }

  Future<AccountUser> me(String token) async {
    _ensureConfigured();
    final res = await http
        .get(_u('/api/me'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取账号信息失败');
    final user = data['user'] is Map<String, dynamic>
        ? data['user'] as Map<String, dynamic>
        : data;
    return AccountUser.fromJson(user);
  }

  /// 拉取云端设置；未设置过时返回 null
  Future<Map<String, dynamic>?> fetchSettings(String token) async {
    _ensureConfigured();
    final res = await http
        .get(_u('/api/settings'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取设置失败');
    final settings = data['settings'];
    if (settings is Map<String, dynamic>) return settings;
    if (data['themeMode'] != null || data['editorFontSize'] != null) {
      return data;
    }
    return null;
  }

  Future<void> pushSettings(
    String token,
    Map<String, dynamic> settings,
  ) async {
    _ensureConfigured();
    final res = await http
        .put(
          _u('/api/settings'),
          headers: _headers(token),
          body: jsonEncode({'settings': settings}),
        )
        .timeout(const Duration(seconds: 20));
    await _decode(res, '同步设置失败');
  }

  (String, AccountUser) _sessionFrom(Map<String, dynamic> data, String what) {
    final token = data['token'] as String? ?? '';
    final userJson = data['user'];
    if (token.isEmpty || userJson is! Map<String, dynamic>) {
      throw AccountException('$what：后端返回数据格式不正确');
    }
    return (token, AccountUser.fromJson(userJson));
  }
}
