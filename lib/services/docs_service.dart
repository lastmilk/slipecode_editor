import 'dart:convert';

import '../config/app_config.dart';
import 'backend_http.dart';

/// 使用文档摘要（列表项，不含正文）
class DocSummary {
  final String id;
  final String title;
  final String updatedAt;
  final String createdAt;

  const DocSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.createdAt,
  });

  factory DocSummary.fromJson(Map<String, dynamic> json) => DocSummary(
        id: (json['id'] ?? '').toString(),
        title: json['title'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
      );
}

/// 使用文档详情（含 Markdown 正文）
class DocDetail extends DocSummary {
  final String content;

  const DocDetail({
    required super.id,
    required super.title,
    required super.updatedAt,
    required super.createdAt,
    required this.content,
  });

  factory DocDetail.fromJson(Map<String, dynamic> json) => DocDetail(
        id: (json['id'] ?? '').toString(),
        title: json['title'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

class DocsException implements Exception {
  final String message;
  const DocsException(this.message);

  @override
  String toString() => message;
}

/// 使用文档 / 门户公开信息客户端
///
/// 后端公开只读接口：
/// - GET /api/docs        已发布文档列表（不含正文）
/// - GET /api/docs/:id    单篇文档（含 Markdown 正文）
/// - GET /api/public/info 门户公开信息（QQ 群号等）
class DocsService {
  DocsService._();

  static final DocsService instance = DocsService._();

  final _client = BackendHttp.client;

  Uri _uri(String path) =>
      Uri.parse('${AppConfig.accountBackendBase}$path');

  Future<List<DocSummary>> listDocs() async {
    final resp = await _client.get(_uri('/api/docs'));
    if (resp.statusCode != 200) {
      throw DocsException('加载文档列表失败（HTTP ${resp.statusCode}）');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = body['docs'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map)
          DocSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<DocDetail> getDoc(String id) async {
    final resp = await _client.get(_uri('/api/docs/$id'));
    if (resp.statusCode != 200) {
      String message = '加载文档失败（HTTP ${resp.statusCode}）';
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        if (body['error'] is String) message = body['error'] as String;
      } catch (_) {}
      throw DocsException(message);
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final doc = body['doc'];
    if (doc is! Map) throw const DocsException('文档数据格式异常');
    return DocDetail.fromJson(Map<String, dynamic>.from(doc));
  }

  /// 官方 QQ 群号（空字符串表示未配置）
  Future<String> fetchQqGroup() async {
    try {
      final resp = await _client.get(_uri('/api/public/info'));
      if (resp.statusCode != 200) return '';
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return (body['qqGroup'] as String? ?? '').trim();
    } catch (_) {
      // 门户信息属于锦上添花，网络失败时静默降级为不展示
      return '';
    }
  }
}
