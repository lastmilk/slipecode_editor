import 'dart:convert';

import '../config/app_config.dart';
import 'backend_http.dart';

/// 一份政策文档（用户协议 / 隐私政策）
class PolicyDocument {
  final String title;
  final String content;
  final String version;
  final String updatedAt;

  const PolicyDocument({
    required this.title,
    required this.content,
    required this.version,
    required this.updatedAt,
  });

  factory PolicyDocument.fromJson(Map<String, dynamic> json) => PolicyDocument(
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        version: json['version'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
      );

  bool get isEmpty => content.trim().isEmpty;
}

/// 两份政策的组合
class PolicyBundle {
  final PolicyDocument userAgreement;
  final PolicyDocument privacyPolicy;

  const PolicyBundle({
    required this.userAgreement,
    required this.privacyPolicy,
  });

  /// 任意一份非空即视为可用
  bool get isNotEmpty =>
      !userAgreement.isEmpty || !privacyPolicy.isEmpty;

  /// 取两份政策中最新的版本号（服务端更新任一份都会递增版本）
  String get latestVersion {
    const fallback = '1.0.0';
    final versions = [
      if (userAgreement.version.isNotEmpty) userAgreement.version,
      if (privacyPolicy.version.isNotEmpty) privacyPolicy.version,
    ];
    return versions.isEmpty ? fallback : versions.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  }
}

class PolicyException implements Exception {
  final String message;
  const PolicyException(this.message);

  @override
  String toString() => message;
}

/// 政策合规客户端
///
/// 后端公开只读接口：GET /api/policies
/// 管理员在后台「政策合规」界面更新后立即生效（版本号自动递增）。
class PolicyService {
  PolicyService._();

  static final PolicyService instance = PolicyService._();

  final _client = BackendHttp.client;

  Uri _uri(String path) => Uri.parse('${AppConfig.accountBackendBase}$path');

  /// 拉取最新政策；网络失败时返回 null（离线兜底，不阻断启动）
  Future<PolicyBundle?> fetchPolicies() async {
    try {
      final resp = await _client.get(_uri('/api/policies')).timeout(
            const Duration(seconds: 10),
          );
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final policies = body['policies'];
      if (policies is! Map) return null;
      PolicyDocument parse(String key) {
        final raw = policies[key];
        if (raw is Map) return PolicyDocument.fromJson(Map<String, dynamic>.from(raw));
        return const PolicyDocument(
          title: '',
          content: '',
          version: '',
          updatedAt: '',
        );
      }

      return PolicyBundle(
        userAgreement: parse('userAgreement'),
        privacyPolicy: parse('privacyPolicy'),
      );
    } catch (_) {
      return null;
    }
  }
}
