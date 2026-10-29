import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/gitee_api_service.dart';
import '../services/gitee_auth_service.dart';
import '../services/gitee_go_templates.dart';
import '../services/git_host.dart';
import '../services/github_api_service.dart' show RepoFile;
import '../services/project_snapshot.dart';

/// Gitee 授权状态
enum GiteeAuthStatus { unknown, signedOut, signingIn, signedIn }

/// Gitee 账号与仓库状态管理
///
/// 与 GitHubProvider 结构保持一致，但 token 由自建后端换取，
/// 仓库推送使用 Gitee Contents API。
class GiteeProvider extends ChangeNotifier {
  GiteeAuthStatus _status = GiteeAuthStatus.unknown;
  GiteeUser? _user;
  String? _token;
  String? _error;

  /// projectPath → repoFullName
  final Map<String, String> _repoMap = {};

  GiteeAuthStatus get status => _status;
  GiteeUser? get user => _user;
  String? get error => _error;

  bool get isConfigured => AppConfig.isGiteeConfigured;
  bool get isSignedIn => _status == GiteeAuthStatus.signedIn && _token != null;

  GiteeApiService? get api => isSignedIn ? GiteeApiService(_token!) : null;

  static const _repoMapPrefix = 'slipecode_gitee_repo::';

  /// 启动时恢复登录状态
  Future<void> init() async {
    await _loadRepoMap();
    final token = await GiteeAuthService.instance.validToken();
    if (token == null || token.isEmpty) {
      _status = GiteeAuthStatus.signedOut;
      notifyListeners();
      return;
    }
    _token = token;
    _status = GiteeAuthStatus.signedIn;
    notifyListeners();
    // 校验 token；网络不可达时降级为未登录，但保留 token 以便下次重试
    try {
      _user = await api!
          .getAuthenticatedUser()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Gitee token 校验失败：$e');
      final isNetworkError = e is TimeoutException || e is SocketException;
      if (!isNetworkError) {
        await GiteeAuthService.instance.clearToken();
        _token = null;
      }
      _status = GiteeAuthStatus.signedOut;
    }
    notifyListeners();
  }

  /// 发起 Gitee OAuth 登录（授权码由后端换取 token）
  Future<bool> signIn() async {
    if (!isConfigured) {
      _error = '未配置 Gitee：请填写 GITEE_CLIENT_ID 与 ACCOUNT_BACKEND_BASE_URL';
      notifyListeners();
      return false;
    }
    _status = GiteeAuthStatus.signingIn;
    _error = null;
    notifyListeners();
    try {
      final result = await GiteeAuthService.instance.signIn();
      _token = result.accessToken;
      _user = await api!.getAuthenticatedUser();
      _status = GiteeAuthStatus.signedIn;
      notifyListeners();
      return true;
    } catch (e) {
      _error = '$e';
      _status = GiteeAuthStatus.signedOut;
      notifyListeners();
      return false;
    }
  }

  Future<void> cancelSignIn() => GiteeAuthService.instance.cancelSignIn();

  Future<void> signOut() async {
    await GiteeAuthService.instance.clearToken();
    _token = null;
    _user = null;
    _status = GiteeAuthStatus.signedOut;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 项目 ↔ 仓库映射
  // ---------------------------------------------------------------------------

  String? repoFor(String projectPath) => _repoMap[projectPath];

  Future<void> linkRepo(String projectPath, String repoFullName) async {
    _repoMap[projectPath] = repoFullName;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_repoMapPrefix$projectPath', repoFullName);
  }

  Future<void> unlinkRepo(String projectPath) async {
    _repoMap.remove(projectPath);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_repoMapPrefix$projectPath');
  }

  Future<void> _loadRepoMap() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_repoMapPrefix)) {
        final value = prefs.getString(key);
        if (value != null) {
          _repoMap[key.substring(_repoMapPrefix.length)] = value;
        }
      }
    }
  }

  /// 为项目创建 Gitee 仓库并建立映射
  Future<GiteeRepo> createRepoForProject(
    String projectPath,
    String repoName, {
    bool private = true,
  }) async {
    final client = api;
    if (client == null) throw StateError('尚未登录 Gitee');
    final repo = await client.createRepo(
      repoName,
      private: private,
      description: 'Created by SLIPE',
    );
    await linkRepo(projectPath, repo.fullName);
    return repo;
  }

  /// 仓库重名时自动追加 _1、_2……
  Future<String> uniqueRepoName(String baseName) async {
    final client = api;
    final login = _user?.login;
    if (client == null || login == null) throw StateError('尚未登录 Gitee');
    for (var i = 0; i <= 20; i++) {
      final candidate = i == 0 ? baseName : '${baseName}_$i';
      final exists = await client.getRepo('$login/$candidate');
      if (exists == null) return candidate;
    }
    throw StateError('同名仓库过多，请换一个仓库名');
  }

  /// 创建仓库并把整个项目（含 Gitee Go 流水线）首次推送到默认分支
  Future<GiteeRepo> createRepoWithInitialPush(
    String projectPath,
    String repoName, {
    bool private = true,
    void Function(String line)? onLog,
  }) async {
    final client = api;
    if (client == null) throw StateError('尚未登录 Gitee');

    // Gitee 仓库名只允许字母/数字/_/-/.,中文名需先清洗，否则服务端 400
    final safeName = sanitizeRepoName(repoName);
    if (safeName != repoName) {
      onLog?.call('    仓库名 "$repoName" 含非法字符，改用 $safeName');
    }
    final resolvedName = await uniqueRepoName(safeName);
    if (resolvedName != safeName) {
      onLog?.call('    仓库 $safeName 已存在，改用 $resolvedName');
    }

    onLog?.call('==> 创建 Gitee 仓库：$resolvedName');
    final repo = await createRepoForProject(
      projectPath,
      resolvedName,
      private: private,
    );
    onLog?.call('    ${repo.htmlUrl}');

    onLog?.call('==> 扫描项目文件');
    final files = await ProjectSnapshot.collect(
      projectPath,
      onSkip: (path) => onLog?.call('    跳过：$path'),
    );
    onLog?.call('    共 ${files.length} 个文件');

    onLog?.call('==> 推送初始代码（Gitee Contents API，逐文件提交）');
    await client.pushFiles(
      repo.fullName,
      files,
      message: 'chore: initial commit from SLIPE',
      branch: repo.defaultBranch,
      onProgress: (done, total) {
        if (done == total || done % 10 == 0) {
          onLog?.call('    已推送 $done/$total');
        }
      },
    );

    if (_isAppTemplate(projectPath) &&
        !await client.fileExists(
          repo.fullName,
          GiteeGoTemplates.workflowPath,
          repo.defaultBranch,
        )) {
      onLog?.call('==> 推送 Gitee Go 构建流水线（仅 Android）');
      await client.pushFiles(
        repo.fullName,
        [
          RepoFile(
            GiteeGoTemplates.workflowPath,
            Uint8List.fromList(
              utf8.encode(GiteeGoTemplates.flutterBuildPipeline),
            ),
          ),
        ],
        message: 'ci: add SLIPE Gitee Go pipeline',
        branch: repo.defaultBranch,
      );
      onLog?.call('    提示：Gitee Go 不支持 macOS Runner，iOS 请使用 GitHub Actions');
    }
    onLog?.call('==> 完成');
    return repo;
  }

  bool _isAppTemplate(String projectPath) {
    try {
      final metaFile = File(p.join(projectPath, '.slipecode.json'));
      if (!metaFile.existsSync()) return true;
      final meta = jsonDecode(metaFile.readAsStringSync());
      if (meta is Map && meta['template'] is String) {
        return meta['template'] == 'app';
      }
    } catch (_) {}
    return true;
  }
}
