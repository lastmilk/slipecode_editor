import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'backend_http.dart';

/// SlipCode 账号用户
class AccountUser {
  final String id;
  final String email;
  final String displayName;

  /// 手机号（注册必填）
  final String phone;

  /// 云端头像地址（为空表示未设置）
  final String avatarUrl;

  /// 云端壁纸版本号（为空表示未上传）
  final String wallpaperVersion;

  const AccountUser({
    required this.id,
    required this.email,
    required this.displayName,
    this.phone = '',
    this.avatarUrl = '',
    this.wallpaperVersion = '',
  });

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
        id: (json['id'] ?? '').toString(),
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ??
            json['display_name'] as String? ??
            '',
        phone: json['phone'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String? ?? '',
        wallpaperVersion: json['wallpaperVersion'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
        'phone': phone,
        'avatarUrl': avatarUrl,
        'wallpaperVersion': wallpaperVersion,
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

  /// 账号后端专用客户端：容忍该后端域名的证书主机名不匹配
  final http.Client _client = BackendHttp.client;

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
  ///
  /// [captcha] 为极验 SDK 返回的四个字段；[captchaPlatform] 用于让后端判断
  /// 当前平台是否支持人机验证（iOS/桌面为 unsupported）。
  Future<(String, AccountUser)> register({
    required String email,
    required String password,
    required String displayName,
    required String phone,
    required String smsCode,
    Map<String, dynamic>? captcha,
    String captchaPlatform = 'android',
  }) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/auth/register'),
          headers: _headers(),
          body: jsonEncode({
            'email': email,
            'password': password,
            'displayName': displayName,
            'phone': phone,
            'smsCode': smsCode,
            'captcha': ?captcha,
            'captchaPlatform': captchaPlatform,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = await _decode(res, '注册失败');
    return _sessionFrom(data, '注册失败');
  }

  /// 发送注册短信验证码
  ///
  /// 返回 `(是否成功, 是否为开发模式, 开发模式验证码)`。
  Future<(bool, bool, String?)> sendSmsCode(String phone) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/auth/sms/send'),
          headers: _headers(),
          body: jsonEncode({'phone': phone}),
        )
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '发送验证码失败');
    return (
      data['ok'] == true,
      data['dev'] == true,
      data['devCode'] as String?,
    );
  }

  Future<(String, AccountUser)> login({
    required String email,
    required String password,
    Map<String, dynamic>? captcha,
    String captchaPlatform = 'android',
  }) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/auth/login'),
          headers: _headers(),
          body: jsonEncode({
            'email': email,
            'password': password,
            'captcha': ?captcha,
            'captchaPlatform': captchaPlatform,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = await _decode(res, '登录失败');
    return _sessionFrom(data, '登录失败');
  }

  Future<AccountUser> me(String token) async {
    _ensureConfigured();
    final res = await _client
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
    final res = await _client
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
    final res = await _client
        .put(
          _u('/api/settings'),
          headers: _headers(token),
          body: jsonEncode({'settings': settings}),
        )
        .timeout(const Duration(seconds: 20));
    await _decode(res, '同步设置失败');
  }

  // ---------------------------------------------------------------------------
  // 项目列表 / 仓库映射云同步
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchProjects(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/projects'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取项目列表失败');
    final list = data['projects'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  Future<void> pushProjects(
    String token,
    List<Map<String, dynamic>> projects,
  ) async {
    _ensureConfigured();
    final res = await _client
        .put(
          _u('/api/projects'),
          headers: _headers(token),
          body: jsonEncode({'projects': projects}),
        )
        .timeout(const Duration(seconds: 20));
    await _decode(res, '同步项目列表失败');
  }

  // ---------------------------------------------------------------------------
  // AI 对话记录云同步
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> fetchChatHistory(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/chat/history'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取对话记录失败');
    final list = data['messages'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  Future<void> pushChatHistory(
    String token,
    List<Map<String, dynamic>> messages,
  ) async {
    _ensureConfigured();
    final res = await _client
        .put(
          _u('/api/chat/history'),
          headers: _headers(token),
          body: jsonEncode({'messages': messages}),
        )
        .timeout(const Duration(seconds: 30));
    await _decode(res, '同步对话记录失败');
  }

  Future<void> deleteChatHistory(String token) async {
    _ensureConfigured();
    final res = await _client
        .delete(_u('/api/chat/history'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    await _decode(res, '清空云端对话记录失败');
  }

  // ---------------------------------------------------------------------------
  // 头像 / 壁纸
  // ---------------------------------------------------------------------------

  /// 上传头像，返回云端头像地址（相对路径）
  Future<String?> uploadAvatar(
    String token,
    Uint8List bytes,
    String mime,
  ) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/me/avatar'),
          headers: _headers(token),
          body: jsonEncode({'base64': base64Encode(bytes), 'mime': mime}),
        )
        .timeout(const Duration(seconds: 60));
    final data = await _decode(res, '上传头像失败');
    return data['avatarUrl'] as String?;
  }

  /// 下载头像字节（相对路径自动拼接后端地址）
  Future<Uint8List?> downloadAvatar(String avatarUrl) async {
    _ensureConfigured();
    if (avatarUrl.isEmpty) return null;
    final uri = avatarUrl.startsWith('http')
        ? Uri.parse(avatarUrl)
        : Uri.parse('${AppConfig.accountBackendBase}$avatarUrl');
    final res = await _client.get(uri).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return null;
    return res.bodyBytes;
  }

  /// 上传壁纸；返回云端版本号（用于判断是否需要重新下载）
  Future<String?> uploadWallpaper(
    String token,
    Uint8List bytes,
    String mime,
  ) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/me/wallpaper'),
          headers: _headers(token),
          body: jsonEncode({'base64': base64Encode(bytes), 'mime': mime}),
        )
        .timeout(const Duration(seconds: 90));
    final data = await _decode(res, '上传壁纸失败');
    return data['version'] as String?;
  }

  /// 下载云端壁纸；没有时返回 null
  Future<({Uint8List bytes, String mime, String version})?> downloadWallpaper(
    String token,
  ) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/me/wallpaper'), headers: _headers(token))
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 404) return null;
    final data = await _decode(res, '下载壁纸失败');
    final raw = data['base64'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return (
      bytes: base64Decode(raw),
      mime: data['mime'] as String? ?? 'image/jpeg',
      version: data['version'] as String? ?? '',
    );
  }

  Future<void> deleteWallpaper(String token) async {
    _ensureConfigured();
    final res = await _client
        .delete(_u('/api/me/wallpaper'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    await _decode(res, '删除云端壁纸失败');
  }

  /// 云端 LLM 模型列表（SLIPE 云端模型预置使用）
  Future<List<Map<String, dynamic>>> fetchLlmModels(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/llm/models'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取云端模型失败');
    final list = data['models'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
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
