import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/credits.dart';
import 'backend_http.dart';

/// SLIPE 账号用户
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

  /// 积分余额
  final int credits;

  /// 当前会员信息
  final MembershipInfo membership;

  const AccountUser({
    required this.id,
    required this.email,
    required this.displayName,
    this.phone = '',
    this.avatarUrl = '',
    this.wallpaperVersion = '',
    this.credits = 0,
    this.membership = const MembershipInfo(),
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
        credits: (json['credits'] as num?)?.toInt() ?? 0,
        membership: json['membership'] is Map
            ? MembershipInfo.fromJson(
                Map<String, dynamic>.from(json['membership'] as Map))
            : const MembershipInfo(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'displayName': displayName,
        'phone': phone,
        'avatarUrl': avatarUrl,
        'wallpaperVersion': wallpaperVersion,
        'credits': credits,
        'membership': {
          'planId': membership.planId,
          'planName': membership.planName,
          'active': membership.active,
          'expiresAt': membership.expiresAt?.toIso8601String(),
          'monthlyCredits': membership.monthlyCredits,
          'checkinReward': membership.checkinReward,
        },
      };

  AccountUser copyWith({
    String? id,
    String? email,
    String? displayName,
    String? phone,
    String? avatarUrl,
    String? wallpaperVersion,
    int? credits,
    MembershipInfo? membership,
  }) {
    return AccountUser(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      wallpaperVersion: wallpaperVersion ?? this.wallpaperVersion,
      credits: credits ?? this.credits,
      membership: membership ?? this.membership,
    );
  }
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
  static const _tokenKey = 'slipe_account_token';

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
  // AI 多会话跨端同步
  // ---------------------------------------------------------------------------

  /// 会话元信息列表（不含 messages）
  Future<List<Map<String, dynamic>>> listConversations(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/conversations'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取会话列表失败');
    final list = data['conversations'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 新建会话（可带客户端生成的 id，避免合并冲突）
  Future<Map<String, dynamic>> createConversation(
    String token, {
    String? id,
    String? title,
  }) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/conversations'),
          headers: _headers(token),
          body: jsonEncode({
            if (id != null) 'id': id,
            if (title != null) 'title': title,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '创建会话失败');
    return Map<String, dynamic>.from(data['conversation'] as Map);
  }

  /// 获取完整会话（含 messages）
  Future<Map<String, dynamic>> fetchConversation(String token, String id) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/conversations/$id'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取会话失败');
    return Map<String, dynamic>.from(data['conversation'] as Map);
  }

  /// 更新会话（标题 / 置顶 / 消息）
  Future<void> updateConversation(
    String token,
    String id, {
    String? title,
    bool? pinned,
    List<Map<String, dynamic>>? messages,
  }) async {
    _ensureConfigured();
    final res = await _client
        .put(
          _u('/api/conversations/$id'),
          headers: _headers(token),
          body: jsonEncode({
            if (title != null) 'title': title,
            if (pinned != null) 'pinned': pinned,
            if (messages != null) 'messages': messages,
          }),
        )
        .timeout(const Duration(seconds: 30));
    await _decode(res, '同步会话失败');
  }

  Future<void> deleteConversation(String token, String id) async {
    _ensureConfigured();
    final res = await _client
        .delete(_u('/api/conversations/$id'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    await _decode(res, '删除会话失败');
  }

  // ---------------------------------------------------------------------------
  // AI 附件（上传限制 / Zip 云端解压）
  // ---------------------------------------------------------------------------

  /// 获取 AI 附件上传限制（管理员可配置）
  Future<Map<String, dynamic>> fetchAiLimits(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/ai/limits'), headers: _headers(token))
        .timeout(const Duration(seconds: 15));
    return _decode(res, '获取附件限制失败');
  }

  /// 上传 Zip 并在服务端解压到临时目录，返回可阅读的文件列表
  Future<Map<String, dynamic>> unzipAiFiles(
    String token, {
    required String name,
    required String dataBase64,
  }) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/ai/files/unzip'),
          headers: _headers(token),
          body: jsonEncode({'name': name, 'dataBase64': dataBase64}),
        )
        .timeout(const Duration(seconds: 90));
    return _decode(res, '云端解压失败');
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

  /// 内置 LLM 模型列表（SLIPE 内置模型）
  Future<({List<BuiltinLlmModel> models, String defaultId})> fetchLlmModels(
    String token,
  ) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/llm/models'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取内置模型失败');
    final list = data['models'];
    final models = list is List
        ? list
            .whereType<Map>()
            .map((e) => BuiltinLlmModel.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <BuiltinLlmModel>[];
    return (
      models: models,
      defaultId: (data['defaultModelId'] ?? '').toString(),
    );
  }

  // ---------------------------------------------------------------------------
  // 积分 / 充值
  // ---------------------------------------------------------------------------

  Future<({int credits, bool checkedInToday})> fetchCredits(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/credits'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取积分失败');
    return (
      credits: (data['credits'] as num?)?.toInt() ?? 0,
      checkedInToday: data['checkedInToday'] == true,
    );
  }

  Future<({bool ok, String message, int credits})> checkin(String token) async {
    _ensureConfigured();
    final res = await _client
        .post(_u('/api/checkin'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '签到失败');
    return (
      ok: data['ok'] == true,
      message: (data['message'] ?? '').toString(),
      credits: (data['credits'] as num?)?.toInt() ?? 0,
    );
  }

  Future<({bool ok, String message, int credits, int amount})>
      redeemActivationCode(String token, String code) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/billing/redeem'),
          headers: _headers(token),
          body: jsonEncode({'code': code.trim()}),
        )
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '兑换失败');
    return (
      ok: data['ok'] == true,
      message: (data['message'] ?? '').toString(),
      credits: (data['credits'] as num?)?.toInt() ?? 0,
      amount: (data['amount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<CreditLogEntry>> fetchCreditLogs(String token) async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/credits/logs'), headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取积分明细失败');
    final list = data['logs'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => CreditLogEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  }

  Future<BillingInfo> fetchBillingPlans() async {
    _ensureConfigured();
    final res = await _client
        .get(_u('/api/billing/plans'))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '获取充值套餐失败');

    final plans = <MembershipPlan>[];
    final rawPlans = data['plans'];
    if (rawPlans is List) {
      for (final item in rawPlans.whereType<Map>()) {
        final map = Map<String, dynamic>.from(item);
        // 兼容旧后端：旧版 plans 是积分包，没有 prices 字段
        if (map['prices'] is Map) plans.add(MembershipPlan.fromJson(map));
      }
    }

    final cycles = <MembershipCycle>[];
    final rawCycles = data['cycles'];
    if (rawCycles is List) {
      for (final item in rawCycles.whereType<Map>()) {
        cycles.add(MembershipCycle.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    final creditPlans = <CreditPlan>[];
    final rawCreditPlans = data['creditPlans'];
    if (rawCreditPlans is List) {
      for (final item in rawCreditPlans.whereType<Map>()) {
        creditPlans.add(CreditPlan.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    final pricing = data['pricing'];
    final wechatPay = data['wechatPay'];
    return BillingInfo(
      plans: plans,
      cycles: cycles,
      creditPlans: creditPlans,
      pricing: pricing is Map
          ? BillingPricing.fromJson(Map<String, dynamic>.from(pricing))
          : const BillingPricing(),
      wechatPay: wechatPay is Map
          ? WechatPayInfo.fromJson(Map<String, dynamic>.from(wechatPay))
          : const WechatPayInfo(),
    );
  }

  /// 创建微信支付订单，返回支付页链接（App 内渲染为二维码）
  Future<({WechatOrder order, String payUrl, String appId})> createWechatOrder(
    String token, {
    required String planId,
    required String cycleId,
  }) async {
    _ensureConfigured();
    final res = await _client
        .post(
          _u('/api/billing/wechat/order'),
          headers: _headers(token),
          body: jsonEncode({'planId': planId, 'cycleId': cycleId}),
        )
        .timeout(const Duration(seconds: 25));
    final data = await _decode(res, '创建支付订单失败');
    final orderJson = data['order'];
    if (orderJson is! Map) {
      throw const AccountException('下单响应缺少订单信息');
    }
    return (
      order: WechatOrder.fromJson(Map<String, dynamic>.from(orderJson)),
      payUrl: (data['payUrl'] ?? '').toString(),
      appId: (data['appId'] ?? '').toString(),
    );
  }

  /// 查询订单状态（服务端会主动向微信查单并结算）
  Future<({WechatOrder order, bool paid, int credits, String warning})>
      fetchWechatOrder(String token, String outTradeNo) async {
    _ensureConfigured();
    final uri = _u('/api/billing/wechat/order').replace(
      queryParameters: {'outTradeNo': outTradeNo},
    );
    final res = await _client
        .get(uri, headers: _headers(token))
        .timeout(const Duration(seconds: 20));
    final data = await _decode(res, '查询支付订单失败');
    final orderJson = data['order'];
    if (orderJson is! Map) {
      throw const AccountException('订单查询响应缺少订单信息');
    }
    final order = WechatOrder.fromJson(Map<String, dynamic>.from(orderJson));
    return (
      order: order,
      paid: data['status'] == 'paid' || order.isPaid,
      credits: (data['credits'] as num?)?.toInt() ?? 0,
      warning: (data['warning'] ?? '').toString(),
    );
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
