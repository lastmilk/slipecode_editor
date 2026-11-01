import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'github_auth_service.dart';

/// 已授权的 GitHub 用户信息
class GitHubUser {
  final String login;
  final String? name;
  final String? avatarUrl;
  final String htmlUrl;

  const GitHubUser({
    required this.login,
    this.name,
    this.avatarUrl,
    required this.htmlUrl,
  });

  factory GitHubUser.fromJson(Map<String, dynamic> json) => GitHubUser(
    login: json['login'] as String,
    name: json['name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    htmlUrl: json['html_url'] as String? ?? '',
  );
}

/// GitHub 仓库
class GitHubRepo {
  final String fullName;
  final String defaultBranch;
  final String htmlUrl;
  final bool private;

  const GitHubRepo({
    required this.fullName,
    required this.defaultBranch,
    required this.htmlUrl,
    required this.private,
  });

  factory GitHubRepo.fromJson(Map<String, dynamic> json) => GitHubRepo(
    fullName: json['full_name'] as String,
    defaultBranch: json['default_branch'] as String? ?? 'main',
    htmlUrl: json['html_url'] as String? ?? '',
    private: json['private'] as bool? ?? true,
  );
}

/// Actions 运行记录
class WorkflowRun {
  final int id;
  final String name;
  final String status; // queued / in_progress / completed
  final String? conclusion; // success / failure / cancelled / ...
  final String htmlUrl;
  final DateTime createdAt;
  final int runNumber;
  final String headBranch;

  const WorkflowRun({
    required this.id,
    required this.name,
    required this.status,
    this.conclusion,
    required this.htmlUrl,
    required this.createdAt,
    required this.runNumber,
    required this.headBranch,
  });

  bool get isCompleted => status == 'completed';

  factory WorkflowRun.fromJson(Map<String, dynamic> json) => WorkflowRun(
    id: json['id'] as int,
    name: json['name'] as String? ?? '',
    status: json['status'] as String? ?? '',
    conclusion: json['conclusion'] as String?,
    htmlUrl: json['html_url'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    runNumber: json['run_number'] as int? ?? 0,
    headBranch: json['head_branch'] as String? ?? '',
  );
}

/// Actions 运行中的单个步骤
class WorkflowStep {
  final int number;
  final String name;
  final String status; // queued / in_progress / completed
  final String? conclusion; // success / failure / skipped / cancelled / ...
  final DateTime? startedAt;
  final DateTime? completedAt;

  const WorkflowStep({
    required this.number,
    required this.name,
    required this.status,
    this.conclusion,
    this.startedAt,
    this.completedAt,
  });

  bool get isRunning => status == 'in_progress';
  bool get isCompleted => status == 'completed';
  bool get isSuccess => isCompleted && (conclusion ?? '') == 'success';

  Duration? get duration {
    if (startedAt == null) return null;
    return (completedAt ?? DateTime.now()).difference(startedAt!);
  }

  factory WorkflowStep.fromJson(Map<String, dynamic> json) => WorkflowStep(
    number: json['number'] as int? ?? 0,
    name: json['name'] as String? ?? '',
    status: json['status'] as String? ?? 'queued',
    conclusion: json['conclusion'] as String?,
    startedAt: DateTime.tryParse(json['started_at'] as String? ?? '')
        ?.toLocal(),
    completedAt: DateTime.tryParse(json['completed_at'] as String? ?? '')
        ?.toLocal(),
  );
}

/// Actions 运行中的一个 Job（包含步骤列表）
class WorkflowJob {
  final int id;
  final String name;
  final String status;
  final String? conclusion;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final List<WorkflowStep> steps;

  const WorkflowJob({
    required this.id,
    required this.name,
    required this.status,
    this.conclusion,
    this.startedAt,
    this.completedAt,
    this.steps = const [],
  });

  bool get isRunning => status == 'in_progress';

  bool get isSuccess =>
      status == 'completed' && (conclusion ?? '') == 'success';

  factory WorkflowJob.fromJson(Map<String, dynamic> json) => WorkflowJob(
    id: json['id'] as int? ?? 0,
    name: json['name'] as String? ?? '',
    status: json['status'] as String? ?? 'queued',
    conclusion: json['conclusion'] as String?,
    startedAt: DateTime.tryParse(json['started_at'] as String? ?? '')
        ?.toLocal(),
    completedAt: DateTime.tryParse(json['completed_at'] as String? ?? '')
        ?.toLocal(),
    steps: (json['steps'] as List? ?? [])
        .map((e) => WorkflowStep.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// Actions 构建产物
class RunArtifact {
  final int id;
  final String name;
  final int sizeInBytes;
  final bool expired;

  const RunArtifact({
    required this.id,
    required this.name,
    required this.sizeInBytes,
    required this.expired,
  });

  factory RunArtifact.fromJson(Map<String, dynamic> json) => RunArtifact(
    id: json['id'] as int,
    name: json['name'] as String? ?? '',
    sizeInBytes: json['size_in_bytes'] as int? ?? 0,
    expired: json['expired'] as bool? ?? false,
  );
}

/// 推送结果
class PushResult {
  final String commitSha;
  final String commitUrl;
  final int fileCount;

  const PushResult({
    required this.commitSha,
    required this.commitUrl,
    required this.fileCount,
  });
}

/// 待推送文件（仓库相对路径 → 内容）
class RepoFile {
  final String path;
  final Uint8List bytes;
  final bool isText;

  const RepoFile(this.path, this.bytes, {this.isText = true});
}

/// GitHub REST API 封装
///
/// 负责仓库创建、基于 Git Data API 的代码推送（无需本地 git）、
/// Actions 工作流触发 / 轮询 / 产物下载。
class GitHubApiService {
  GitHubApiService(this._token);

  final String _token;
  final http.Client _client = http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.apiBase}$path').replace(queryParameters: query);

  void dispose() => _client.close();

  // ---------------------------------------------------------------------------
  // 基础请求
  // ---------------------------------------------------------------------------

  /// 统一的网络请求超时时间。
  /// 启动时 token 校验若卡住会导致首屏白屏，因此所有请求都必须带超时。
  static const _timeout = Duration(seconds: 10);

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    final res = await _client
        .get(_u(path, query), headers: _headers)
        .timeout(_timeout);
    _check(res, 'GET $path');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _client
        .post(
          _u(path),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    _check(res, 'POST $path');
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _patchJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _client
        .patch(
          _u(path),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    _check(res, 'PATCH $path');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Never _throw(String what, http.Response res) {
    String detail = '';
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      detail = body['message'] as String? ?? '';
      final errors = body['errors'];
      if (errors is List && errors.isNotEmpty) {
        detail += ' ${errors.first}';
      }
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

  Future<GitHubUser> getAuthenticatedUser() async {
    final json = await _getJson('/user');
    return GitHubUser.fromJson(json);
  }

  /// 创建私有/公开仓库（在授权用户名下）
  ///
  /// 使用 `auto_init: true`：仓库创建后立即带有初始提交与默认分支，
  /// 可避免空仓库下 git 数据接口返回 409（`Git Repository is empty`）。
  Future<GitHubRepo> createRepo(
    String name, {
    bool private = true,
    String description = '',
  }) async {
    final json = await _postJson('/user/repos', {
      'name': name,
      'private': private,
      'description': description,
      'auto_init': true,
    });
    return GitHubRepo.fromJson(json);
  }

  /// 获取仓库信息；不存在时返回 null
  Future<GitHubRepo?> getRepo(String fullName) async {
    final res = await _client
        .get(_u('/repos/$fullName'), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode == 404) return null;
    _check(res, 'GET /repos/$fullName');
    return GitHubRepo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// 判断仓库中是否存在某个文件
  Future<bool> fileExists(String fullName, String path, String branch) async {
    final res = await _client
        .get(
          _u('/repos/$fullName/contents/$path', {'ref': branch}),
          headers: _headers,
        )
        .timeout(_timeout);
    if (res.statusCode == 404) return false;
    _check(res, 'GET contents/$path');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Git Data API 推送（无需本地 git）
  // ---------------------------------------------------------------------------

  /// 推送一批文件到指定分支（单次 commit）。
  ///
  /// - 空仓库 / 分支并发创建等场景，GitHub 会返回 409 或 422；
  ///   这里最多重试 3 次（重新读取 HEAD 后再推送），避免建仓后首次推送失败；
  /// - 文本文件直接内联 content，二进制文件先创建 blob。
  Future<PushResult> pushFiles(
    String fullName,
    List<RepoFile> files, {
    required String message,
    String branch = 'main',
  }) async {
    if (files.isEmpty) {
      throw ArgumentError('没有需要推送的文件');
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _pushFilesOnce(
          fullName,
          files,
          message: message,
          branch: branch,
        );
      } catch (e) {
        lastError = e;
        final retryable =
            e is HttpExceptionWithBody &&
            (e.message.contains('HTTP 409') || e.message.contains('HTTP 422'));
        if (!retryable || attempt == 2) rethrow;
        await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    throw lastError!;
  }

  /// 单次推送实现（分支并发变化时由 [pushFiles] 重试）
  Future<PushResult> _pushFilesOnce(
    String fullName,
    List<RepoFile> files, {
    required String message,
    String branch = 'main',
  }) async {
    // 1. 取当前分支 HEAD（空仓库会 404/409）
    String? headCommitSha;
    String? baseTreeSha;
    final refRes = await _client
        .get(_u('/repos/$fullName/git/ref/heads/$branch'), headers: _headers)
        .timeout(_timeout);
    if (refRes.statusCode == 200) {
      final ref = jsonDecode(refRes.body) as Map<String, dynamic>;
      headCommitSha = (ref['object'] as Map<String, dynamic>)['sha'] as String;
      final commit = await _getJson(
        '/repos/$fullName/git/commits/$headCommitSha',
      );
      baseTreeSha = (commit['tree'] as Map<String, dynamic>)['sha'] as String;
    } else if (refRes.statusCode != 404 && refRes.statusCode != 409) {
      _check(refRes, 'GET git/ref/heads/$branch');
    }

    // 2. 构造 tree entries
    final entries = <Map<String, dynamic>>[];
    for (final file in files) {
      if (file.isText) {
        entries.add({
          'path': file.path,
          'mode': '100644',
          'type': 'blob',
          'content': utf8.decode(file.bytes, allowMalformed: true),
        });
      } else {
        final blob = await _postJson('/repos/$fullName/git/blobs', {
          'content': base64Encode(file.bytes),
          'encoding': 'base64',
        });
        entries.add({
          'path': file.path,
          'mode': '100644',
          'type': 'blob',
          'sha': blob['sha'],
        });
      }
    }

    // 3. 创建 tree（增量更新必须带 base_tree，否则会删除未包含的文件）
    final tree = await _postJson('/repos/$fullName/git/trees', {
      'base_tree': ?baseTreeSha,
      'tree': entries,
    });
    final treeSha = tree['sha'] as String;

    // 4. 创建 commit
    final commit = await _postJson('/repos/$fullName/git/commits', {
      'message': message,
      'tree': treeSha,
      if (headCommitSha != null) 'parents': [headCommitSha],
    });
    final commitSha = commit['sha'] as String;
    final commitUrl = commit['html_url'] as String? ?? '';

    // 5. 更新 / 创建 ref
    if (headCommitSha != null) {
      await _patchJson('/repos/$fullName/git/refs/heads/$branch', {
        'sha': commitSha,
      });
    } else {
      await _postJson('/repos/$fullName/git/refs', {
        'ref': 'refs/heads/$branch',
        'sha': commitSha,
      });
    }

    return PushResult(
      commitSha: commitSha,
      commitUrl: commitUrl,
      fileCount: files.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// GitHub Actions 接口的 workflow 参数只接受「文件 basename」或数字 ID，
  /// 传完整路径（如 .github/workflows/x.yml）会返回 404。
  static String _workflowRef(String pathOrId) {
    if (pathOrId.contains('/')) return pathOrId.split('/').last;
    return pathOrId;
  }

  /// 触发 workflow_dispatch
  Future<void> dispatchWorkflow(
    String fullName,
    String workflowFile, {
    String ref = 'main',
    Map<String, String> inputs = const {},
  }) async {
    final res = await _client.post(
      _u(
        '/repos/$fullName/actions/workflows/${_workflowRef(workflowFile)}/dispatches',
      ),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'ref': ref, 'inputs': inputs}),
    );
    if (res.statusCode != 204) {
      _check(res, 'POST dispatches');
    }
  }

  /// 查询某工作流在指定时间之后创建的最新运行
  Future<WorkflowRun?> latestRunSince(
    String fullName,
    String workflowFile,
    DateTime since, {
    String branch = 'main',
  }) async {
    final res = await _client.get(
      _u(
        '/repos/$fullName/actions/workflows/${_workflowRef(workflowFile)}/runs',
        {
          'branch': branch,
          'per_page': '5',
          'created':
              '>=${since.toUtc().subtract(const Duration(seconds: 5)).toIso8601String()}',
        },
      ),
      headers: _headers,
    );
    if (res.statusCode == 404) return null;
    _check(res, 'GET workflow runs');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final runs = (body['workflow_runs'] as List? ?? [])
        .map((e) => WorkflowRun.fromJson(e as Map<String, dynamic>))
        .toList();
    if (runs.isEmpty) return null;
    return runs.first;
  }

  /// 获取运行详情
  Future<WorkflowRun> getRun(String fullName, int runId) async {
    final json = await _getJson('/repos/$fullName/actions/runs/$runId');
    return WorkflowRun.fromJson(json);
  }

  /// 列出某次运行的产物
  Future<List<RunArtifact>> listArtifacts(String fullName, int runId) async {
    final json = await _getJson(
      '/repos/$fullName/actions/runs/$runId/artifacts',
    );
    return (json['artifacts'] as List? ?? [])
        .map((e) => RunArtifact.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 列出某次运行的 Job 与步骤（用于展示完整构建流程）
  Future<List<WorkflowJob>> listJobs(String fullName, int runId) async {
    final json = await _getJson('/repos/$fullName/actions/runs/$runId/jobs', {
      'per_page': '20',
    });
    return (json['jobs'] as List? ?? [])
        .map((e) => WorkflowJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 取消一次正在运行的工作流
  Future<void> cancelRun(String fullName, int runId) async {
    final res = await _client
        .post(
          _u('/repos/$fullName/actions/runs/$runId/cancel'),
          headers: _headers,
        )
        .timeout(_timeout);
    // 202 表示已接受取消请求；409 表示运行已结束（无需报错）
    if (res.statusCode == 202 || res.statusCode == 409) return;
    _check(res, '取消工作流');
  }

  /// 下载产物（返回 zip 字节）。
  ///
  /// 手动跟随 302，避免把 Authorization 头泄露给签名 URL 域名。
  Future<Uint8List> downloadArtifact(String fullName, int artifactId) async {
    final request =
        http.Request(
            'GET',
            _u('/repos/$fullName/actions/artifacts/$artifactId/zip'),
          )
          ..headers.addAll(_headers)
          ..followRedirects = false;
    final streamed = await _client.send(request);
    if (streamed.statusCode != 302) {
      final body = await streamed.stream.bytesToString();
      throw HttpExceptionWithBody('下载产物失败（HTTP ${streamed.statusCode}）', body);
    }
    final location = streamed.headers['location'];
    if (location == null) {
      throw const HttpExceptionWithBody('下载产物失败：缺少重定向地址', '');
    }
    final zipRes = await http.get(Uri.parse(location));
    if (zipRes.statusCode != 200) {
      throw HttpExceptionWithBody('下载产物失败（HTTP ${zipRes.statusCode}）', '');
    }
    return zipRes.bodyBytes;
  }
}
