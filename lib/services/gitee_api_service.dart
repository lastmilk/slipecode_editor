import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'github_api_service.dart' show PushResult, RepoFile;
import 'github_auth_service.dart' show HttpExceptionWithBody;

/// 已授权的 Gitee 用户信息
class GiteeUser {
  final String login;
  final String? name;
  final String? avatarUrl;
  final String htmlUrl;

  const GiteeUser({
    required this.login,
    this.name,
    this.avatarUrl,
    required this.htmlUrl,
  });

  factory GiteeUser.fromJson(Map<String, dynamic> json) => GiteeUser(
        login: json['login'] as String? ?? '',
        name: json['name'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        htmlUrl: json['html_url'] as String? ?? '',
      );
}

/// Gitee 仓库
class GiteeRepo {
  final String fullName;
  final String defaultBranch;
  final String htmlUrl;
  final bool private;

  const GiteeRepo({
    required this.fullName,
    required this.defaultBranch,
    required this.htmlUrl,
    required this.private,
  });

  factory GiteeRepo.fromJson(Map<String, dynamic> json) => GiteeRepo(
        fullName: json['full_name'] as String? ?? '',
        // Gitee 新仓库默认分支通常为 master
        defaultBranch: json['default_branch'] as String? ?? 'master',
        htmlUrl: json['html_url'] as String? ?? '',
        private: json['private'] as bool? ?? true,
      );
}

/// Gitee OpenAPI v5 封装
///
/// Gitee 没有与 GitHub Git Data API 等价的批量提交接口，
/// 这里通过 Contents API 逐文件提交（自动判断新建/更新）。
class GiteeApiService {
  GiteeApiService(this._token);

  final String _token;
  final http.Client _client = http.Client();

  Uri _u(String path, [Map<String, String>? query]) => Uri.parse(
        '${AppConfig.giteeApiBase}$path',
      ).replace(queryParameters: {
        'access_token': _token,
        ...?query,
      });

  void dispose() => _client.close();

  // ---------------------------------------------------------------------------
  // 基础请求
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _getJson(String path,
      [Map<String, String>? query]) async {
    final res = await _client.get(_u(path, query));
    _check(res, 'GET $path');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = http.Request(method, _u(path))
      ..headers['Content-Type'] = 'application/json;charset=UTF-8'
      ..body = jsonEncode(body);
    final streamed = await _client.send(req);
    final res = await http.Response.fromStream(streamed);
    _check(res, '$method $path');
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Never _throw(String what, http.Response res) {
    String detail = '';
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      detail = (body['message'] ?? body['error'] ?? '').toString();
    } catch (_) {}
    throw HttpExceptionWithBody(
      '$what 失败（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
      res.body,
    );
  }

  void _check(http.Response res, String what) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throw(what, res);
    }
  }

  // ---------------------------------------------------------------------------
  // 用户 / 仓库
  // ---------------------------------------------------------------------------

  Future<GiteeUser> getAuthenticatedUser() async {
    final json = await _getJson('/user');
    return GiteeUser.fromJson(json);
  }

  /// 创建仓库（在当前授权用户名下）
  Future<GiteeRepo> createRepo(
    String name, {
    bool private = true,
    String description = '',
  }) async {
    final json = await _sendJson('POST', '/user/repos', {
      'name': name,
      'private': private,
      'description': description,
      // 用 README 初始化，确保默认分支存在（Contents API 需要已有分支）
      'auto_init': true,
    });
    return GiteeRepo.fromJson(json);
  }

  /// 获取仓库；不存在时返回 null
  Future<GiteeRepo?> getRepo(String fullName) async {
    final res = await _client.get(_u('/repos/$fullName'));
    if (res.statusCode == 404) return null;
    _check(res, 'GET /repos/$fullName');
    return GiteeRepo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// 判断仓库中是否存在某个文件
  Future<bool> fileExists(String fullName, String path, String branch) async {
    final res = await _client.get(
      _u('/repos/$fullName/contents/${_encodePath(path)}', {'ref': branch}),
    );
    if (res.statusCode == 404) return false;
    _check(res, 'GET contents/$path');
    return true;
  }

  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// 读取文件当前 blob sha；文件不存在时返回 null
  Future<String?> _fileSha(
    String fullName,
    String path,
    String branch,
  ) async {
    final res = await _client.get(
      _u('/repos/$fullName/contents/${_encodePath(path)}', {'ref': branch}),
    );
    if (res.statusCode == 404) return null;
    _check(res, 'GET contents/$path');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    // 文件返回单个对象；目录返回数组（视为没有可覆盖的同名文件）
    if (json['sha'] is String) return json['sha'] as String;
    return null;
  }

  // ---------------------------------------------------------------------------
  // 文件推送（Contents API）
  // ---------------------------------------------------------------------------

  /// 逐文件推送，返回最后一次提交信息。
  ///
  /// 空仓库首次提交时 Gitee 会自动创建分支；[branch] 需与仓库默认分支一致。
  Future<PushResult> pushFiles(
    String fullName,
    List<RepoFile> files, {
    required String message,
    String branch = 'master',
    void Function(int done, int total)? onProgress,
  }) async {
    if (files.isEmpty) {
      throw ArgumentError('没有需要推送的文件');
    }

    String lastCommitSha = '';
    String lastCommitUrl = '';
    var done = 0;

    for (final file in files) {
      final path = '/repos/$fullName/contents/${_encodePath(file.path)}';
      final sha = await _fileSha(fullName, file.path, branch);
      final body = <String, dynamic>{
        'content': base64Encode(file.bytes),
        'message': message,
        'branch': branch,
      };
      if (sha != null) body['sha'] = sha;

      final json = await _sendJson(sha == null ? 'POST' : 'PUT', path, body);
      final commit = json['commit'];
      if (commit is Map) {
        lastCommitSha = commit['sha'] as String? ?? lastCommitSha;
        lastCommitUrl = commit['html_url'] as String? ?? lastCommitUrl;
      }
      done++;
      onProgress?.call(done, files.length);
    }

    return PushResult(
      commitSha: lastCommitSha,
      commitUrl: lastCommitUrl,
      fileCount: files.length,
    );
  }
}
