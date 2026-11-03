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

  /// 统一的网络请求超时时间，避免首屏因网络卡死。
  static const _timeout = Duration(seconds: 10);

  /// 把响应体解码为 Map；Gitee 部分错误场景会返回 List（如参数校验失败），
  /// 直接 as Map 会抛出难以定位的 type cast 错误，这里统一转为可读异常。
  Map<String, dynamic> _decodeMap(http.Response res, String what) {
    if (res.body.isEmpty) return {};
    final decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) return decoded;
    final preview =
        res.body.length > 200 ? '${res.body.substring(0, 200)}…' : res.body;
    throw HttpExceptionWithBody(
      '$what 返回了非对象数据（${decoded.runtimeType}）：$preview',
      res.body,
    );
  }

  Future<Map<String, dynamic>> _getJson(String path,
      [Map<String, String>? query]) async {
    final res = await _client.get(_u(path, query)).timeout(_timeout);
    _check(res, 'GET $path');
    return _decodeMap(res, 'GET $path');
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = http.Request(method, _u(path))
      ..headers['Content-Type'] = 'application/json;charset=UTF-8'
      ..body = jsonEncode(body);
    final streamed = await _client.send(req).timeout(_timeout);
    final res = await http.Response.fromStream(streamed);
    _check(res, '$method $path');
    return _decodeMap(res, '$method $path');
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

  /// 列出通过 SLIPE 创建的 Gitee 仓库（按创建描述识别）
  ///
  /// 只返回当前授权用户自己名下的仓库，避免把协作仓库也算进来。
  Future<List<GiteeRepo>> listSlipeRepos() async {
    const marker = 'created by slipe';
    final repos = <GiteeRepo>[];
    for (var page = 1; page <= 5; page++) {
      final res = await _client
          .get(_u('/user/repos', {
            'page': '$page',
            'per_page': '100',
            'sort': 'updated',
            'direction': 'desc',
            'affiliation': 'owner',
          }))
          .timeout(const Duration(seconds: 20));
      _check(res, 'GET /user/repos');
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        throw HttpExceptionWithBody(
          'GET /user/repos 返回了非列表数据（${decoded.runtimeType}）',
          res.body,
        );
      }
      if (decoded.isEmpty) break;
      for (final item in decoded) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final description =
            (map['description'] as String? ?? '').toLowerCase();
        if (description.contains(marker)) {
          repos.add(GiteeRepo.fromJson(map));
        }
      }
      if (decoded.length < 100) break;
    }
    return repos;
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
    return GiteeRepo.fromJson(_decodeMap(res, 'GET /repos/$fullName'));
  }

  /// 为仓库开通 Gitee Go（云原生构建）
  ///
  /// POST /v5/repos/{owner}/{repo}/open（formData: access_token）
  /// 文档：https://gitee.com/api/v5/swagger#/postV5ReposOwnerRepoOpen
  ///
  /// 新仓库必须先开通 Gitee Go，`.workflow/*.yml` 才会被识别并触发构建。
  /// 幂等：已开通的仓库再次调用同样返回成功。
  Future<bool> openGiteeGo(String fullName) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConfig.giteeApiBase}/repos/$fullName/open'),
    )..fields['access_token'] = _token;
    final streamed = await _client.send(req).timeout(_timeout);
    final res = await http.Response.fromStream(streamed);
    // 201 Created 表示开通成功；已开通时返回 200/204
    if (res.statusCode >= 200 && res.statusCode < 300) return true;
    _throw('开通 Gitee Go（$fullName）', res);
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
    final decoded = jsonDecode(res.body);
    // 目录返回数组（视为没有可覆盖的同名文件）
    if (decoded is List) return null;
    final json = decoded as Map<String, dynamic>;
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
