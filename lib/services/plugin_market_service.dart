import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/plugin.dart';
import 'account_service.dart';
import 'backend_http.dart';

/// 插件市场客户端（对接后端 `/api/plugins`）
///
/// 与社区 Payload 市场完全独立：这里只处理 IDE 插件。
class PluginMarketService {
  PluginMarketService._();

  static final PluginMarketService instance = PluginMarketService._();

  final http.Client _client = BackendHttp.client;
  final AccountService _account = AccountService.instance;

  bool get isConfigured => AppConfig.isAccountBackendConfigured;

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.accountBackendBase}$path')
          .replace(queryParameters: query);

  Map<String, String> _headers({String? token}) => {
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
    throw PluginMarketException(
      '$what（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
    );
  }

  Map<String, dynamic> _decode(http.Response res, String what) {
    if (res.statusCode < 200 || res.statusCode >= 300) _fail(res, what);
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 市场列表（公开，无需登录）
  Future<PluginMarketPage> list({
    String query = '',
    String category = '',
    String capability = '',
    String sort = 'popular',
  }) async {
    if (!isConfigured) {
      throw const PluginMarketException('未配置账号后端，无法访问插件市场');
    }
    final params = <String, String>{
      if (query.trim().isNotEmpty) 'q': query.trim(),
      if (category.isNotEmpty) 'category': category,
      if (capability.isNotEmpty) 'capability': capability,
      'sort': sort,
    };
    final res = await _client
        .get(_u('/api/plugins', params), headers: _headers())
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '获取插件市场失败');
    return PluginMarketPage(
      plugins: _pluginsFrom(data['plugins']),
      total: (data['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// 安装（需登录）：返回服务端记录的插件（含清单）
  ///
  /// [id] 传市场记录 id（[PluginManifest.marketId]）或插件 slug 均可。
  Future<PluginManifest> install(String id) async {
    final token = await _account.savedToken;
    if (token == null || token.isEmpty) {
      throw const PluginMarketException('请先登录 SLIPE 账号后再安装插件');
    }
    final res = await _client
        .post(
          _u('/api/plugins/${Uri.encodeComponent(id)}/install'),
          headers: _headers(token: token),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '安装插件失败');
    final plugin = data['plugin'];
    if (plugin is! Map) throw const PluginMarketException('插件清单为空');
    final manifest = plugin['manifest'];
    if (manifest is! Map) throw const PluginMarketException('插件清单为空');
    return PluginManifest.fromJson(Map<String, dynamic>.from(manifest));
  }

  /// 兑换官网生成的一次性深链凭证。凭证短时有效且只能使用一次，
  /// URL 中不携带账号令牌。
  Future<PluginManifest> redeemInstallTicket(String ticket) async {
    if (ticket.trim().isEmpty) {
      throw const PluginMarketException('安装凭证为空');
    }
    final res = await _client
        .post(
          _u('/api/plugins/install-ticket/redeem'),
          headers: _headers(),
          body: jsonEncode({'ticket': ticket}),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decode(res, '兑换安装凭证失败');
    final plugin = data['plugin'];
    if (plugin is! Map || plugin['manifest'] is! Map) {
      throw const PluginMarketException('插件清单为空');
    }
    return PluginManifest.fromJson(
      Map<String, dynamic>.from(plugin['manifest'] as Map),
    );
  }

  List<PluginManifest> _pluginsFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          PluginManifest.fromJson({
            // 服务端把清单字段摊平在顶层，这里拼回 manifest 结构
            ...Map<String, dynamic>.from(item),
            // 插件标识用 slug，id 是市场记录 id
            'id': item['slug'] ?? item['id'] ?? '',
            'marketId': item['id'] ?? '',
            'contributes': item['contributes'] ?? const {},
          }),
    ];
  }
}

/// 市场列表返回
class PluginMarketPage {
  const PluginMarketPage({required this.plugins, required this.total});

  final List<PluginManifest> plugins;
  final int total;
}

class PluginMarketException implements Exception {
  const PluginMarketException(this.message);

  final String message;

  @override
  String toString() => message;
}
