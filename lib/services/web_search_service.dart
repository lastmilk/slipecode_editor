import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'backend_http.dart';

/// 联网搜索结果（由后端代理 DeepSeek Search）
class WebSearchHit {
  final String title;
  final String url;
  final String summary;

  const WebSearchHit({
    required this.title,
    required this.url,
    required this.summary,
  });
}

/// 联网搜索（/search 指令的底层实现）
///
/// 客户端只带账号 token 调后端 `/api/ai/search`，由后端使用配置的
/// DeepSeek 线路调用官方 Search API，避免在客户端保存额外的 Key。
class WebSearchService {
  WebSearchService._();

  static final WebSearchService instance = WebSearchService._();

  final http.Client _client = BackendHttp.client;

  Future<List<WebSearchHit>> search({
    required String accountToken,
    required String query,
    int count = 5,
  }) async {
    final uri = Uri.parse(
      '${AppConfig.accountBackendBase}/api/ai/search',
    );
    final res = await _client
        .post(
          uri,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $accountToken',
          },
          body: jsonEncode({'query': query, 'count': count}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String detail = '';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        detail = (data['error'] ?? '').toString();
      } catch (_) {}
      throw Exception(
        '联网搜索失败（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
      );
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final results = data['results'];
    if (results is! List) return const [];
    return [
      for (final item in results)
        if (item is Map)
          WebSearchHit(
            title: (item['title'] ?? '').toString(),
            url: (item['url'] ?? '').toString(),
            summary: (item['summary'] ?? item['snippet'] ?? '').toString(),
          ),
    ];
  }

  /// 拼成给模型阅读的文本
  static String formatHits(List<WebSearchHit> hits, String query) {
    if (hits.isEmpty) return '联网搜索「$query」没有找到结果。';
    final buffer = StringBuffer('联网搜索「$query」结果：\n');
    for (var i = 0; i < hits.length; i++) {
      final hit = hits[i];
      buffer.writeln('${i + 1}. ${hit.title}\n   ${hit.url}\n   ${hit.summary}');
    }
    return buffer.toString();
  }
}
