import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'backend_http.dart';
import 'github_api_service.dart' show WorkflowJob;

/// 服务端构建监听记录
class BuildWatch {
  final String id;
  final String repo;
  final int runId;
  final String status; // queued / in_progress / completed
  final String? conclusion;
  final String htmlUrl;
  final List<WorkflowJob> jobs;
  final bool artifactReady;
  final String artifactName;
  final int artifactSize;
  final String error;

  const BuildWatch({
    required this.id,
    required this.repo,
    required this.runId,
    required this.status,
    this.conclusion,
    required this.htmlUrl,
    this.jobs = const [],
    this.artifactReady = false,
    this.artifactName = '',
    this.artifactSize = 0,
    this.error = '',
  });

  bool get isCompleted => status == 'completed';

  factory BuildWatch.fromJson(Map<String, dynamic> json) => BuildWatch(
    id: json['id'] as String? ?? '',
    repo: json['repo'] as String? ?? '',
    runId: json['runId'] as int? ?? 0,
    status: json['status'] as String? ?? '',
    conclusion: json['conclusion'] as String?,
    htmlUrl: json['htmlUrl'] as String? ?? '',
    jobs: (json['jobs'] as List? ?? [])
        .map((e) => WorkflowJob.fromJson(e as Map<String, dynamic>))
        .toList(),
    artifactReady: json['artifactReady'] == true,
    artifactName: json['artifactName'] as String? ?? '',
    artifactSize: json['artifactSize'] as int? ?? 0,
    error: json['error'] as String? ?? '',
  );
}

/// 服务端构建监听客户端
///
/// 登录用户的构建监听放在服务端：退出构建页 / 退出 IDE 后仍持续轮询，
/// 回到应用时从服务端恢复最新进度；构建产物可先下载到服务端再下发，
/// 缓解国内直连 GitHub 的慢速问题。
class BuildWatchService {
  BuildWatchService._();

  static final BuildWatchService instance = BuildWatchService._();

  final http.Client _client = BackendHttp.client;

  bool get isConfigured => AppConfig.isAccountBackendConfigured;

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.accountBackendBase}$path')
          .replace(queryParameters: query);

  Map<String, String> _headers(String accountToken) => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $accountToken',
  };

  /// 注册（或复用）一次构建监听
  Future<BuildWatch?> register({
    required String accountToken,
    required String githubToken,
    required String repo,
    required int runId,
    required String runUrl,
    required String buildType,
  }) async {
    if (!isConfigured) return null;
    try {
      final res = await _client
          .post(
            _u('/api/build/watch'),
            headers: _headers(accountToken),
            body: jsonEncode({
              'repo': repo,
              'runId': runId,
              'runUrl': runUrl,
              'buildType': buildType,
              'githubToken': githubToken,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 && res.statusCode != 201) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final watch = data['watch'];
      if (watch is! Map<String, dynamic>) return null;
      return BuildWatch.fromJson(watch);
    } catch (_) {
      return null;
    }
  }

  /// 查询某次监听的当前状态
  Future<BuildWatch?> fetch({
    required String accountToken,
    required String id,
  }) async {
    if (!isConfigured || id.isEmpty) return null;
    try {
      final res = await _client
          .get(_u('/api/build/watch/$id'), headers: _headers(accountToken))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final watch = data['watch'];
      if (watch is! Map<String, dynamic>) return null;
      return BuildWatch.fromJson(watch);
    } catch (_) {
      return null;
    }
  }

  /// 查询仓库最新的一条监听（用于重新打开 IDE 后恢复进度）
  Future<BuildWatch?> latest({
    required String accountToken,
    required String repo,
  }) async {
    if (!isConfigured || repo.isEmpty) return null;
    try {
      final res = await _client
          .get(
            _u('/api/build/watch', {'repo': repo}),
            headers: _headers(accountToken),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final watch = data['watch'];
      if (watch is! Map<String, dynamic>) return null;
      return BuildWatch.fromJson(watch);
    } catch (_) {
      return null;
    }
  }

  /// 从服务端下载已中转的构建产物（zip 字节）
  Future<Uint8List?> downloadArtifact({
    required String accountToken,
    required String id,
  }) async {
    if (!isConfigured || id.isEmpty) return null;
    try {
      final res = await _client
          .get(
            _u('/api/build/watch/$id/artifact'),
            headers: _headers(accountToken),
          )
          .timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
