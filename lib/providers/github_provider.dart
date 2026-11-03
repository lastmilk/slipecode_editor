import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../payloads/project_payload.dart';
import '../services/build_service.dart';
import '../services/git_host.dart';
import '../services/github_api_service.dart';
import '../services/github_auth_service.dart';
import '../services/project_history_service.dart';
import '../services/project_snapshot.dart';

/// GitHub 授权状态
enum GitHubAuthStatus { unknown, signedOut, signingIn, signedIn }

/// GitHub 账号与仓库状态管理
///
/// - 维护 OAuth(后端换取 token) 登录状态与 token 持久化
/// - 维护「本地项目路径 → GitHub 仓库」的映射
class GitHubProvider extends ChangeNotifier {
  GitHubAuthStatus _status = GitHubAuthStatus.unknown;
  GitHubUser? _user;
  String? _token;
  String? _error;

  /// projectPath → repoFullName
  final Map<String, String> _repoMap = {};

  GitHubAuthStatus get status => _status;
  GitHubUser? get user => _user;
  String? get error => _error;

  bool get isConfigured => AppConfig.isConfigured;
  bool get isSignedIn => _status == GitHubAuthStatus.signedIn && _token != null;

  /// 当前 OAuth access token（服务端构建监听需要用它访问 GitHub API）
  String? get token => _token;

  /// 已登录时返回 API 客户端
  GitHubApiService? get api => isSignedIn ? GitHubApiService(_token!) : null;

  static const _repoMapPrefix = 'slipe_repo::';

  /// 启动时恢复登录状态
  Future<void> init() async {
    await _loadRepoMap();
    final token = await GitHubAuthService.instance.savedToken;
    if (token == null || token.isEmpty) {
      _status = GitHubAuthStatus.signedOut;
      notifyListeners();
      return;
    }
    _token = token;
    // 先不标记为已登录：校验拿到真实用户后再切换状态，
    // 避免 UI 在拿到用户前显示上个平台/旧账号信息。
    _status = GitHubAuthStatus.unknown;
    notifyListeners();
    // 校验 token 并拉取用户信息（网络不可达时降级为未登录，但保留 token 以便下次重试）
    try {
      final user = await GitHubApiService(token).getAuthenticatedUser().timeout(
        const Duration(seconds: 10),
      );
      _assertGitHubAccount(user);
      _user = user;
      _status = GitHubAuthStatus.signedIn;
    } catch (e) {
      debugPrint('GitHub token 校验失败：$e');
      final isNetworkError = e is TimeoutException || e is SocketException;
      if (!isNetworkError) {
        // 401 等确定性失败才清除 token
        await GitHubAuthService.instance.clearToken();
        _token = null;
      }
      _status = GitHubAuthStatus.signedOut;
      _user = null;
    }
    notifyListeners();
  }

  /// 发起 OAuth 登录（后端用 client_secret 换取 token）
  Future<bool> signIn() async {
    if (!isConfigured) {
      _error = t('github.error.notConfigured');
      notifyListeners();
      return false;
    }
    _status = GitHubAuthStatus.signingIn;
    _error = null;
    // 清掉上一次的用户信息，避免登录失败时仍然显示旧账号
    _user = null;
    notifyListeners();
    try {
      final result = await GitHubAuthService.instance.signIn();
      _token = result.accessToken;
      // api getter 依赖 signedIn 状态，必须直接构造，否则 api! 会空指针崩溃
      final user = await GitHubApiService(result.accessToken)
          .getAuthenticatedUser()
          .timeout(const Duration(seconds: 15));
      // OAuth 配置/后端串台保护：返回的不是 GitHub 账号时拒绝登录
      _assertGitHubAccount(user);
      _user = user;
      _status = GitHubAuthStatus.signedIn;
      notifyListeners();
      return true;
    } catch (e) {
      _error = '$e';
      _status = GitHubAuthStatus.signedOut;
      notifyListeners();
      return false;
    }
  }

  /// 校验授权结果确实是 GitHub 账号
  void _assertGitHubAccount(GitHubUser user) {
    if (user.login.trim().isEmpty ||
        !user.htmlUrl.trim().toLowerCase().contains('github.com')) {
      throw StateError(
        'GitHub 授权返回的不是 GitHub 账号（${user.login}），请检查 OAuth 配置',
      );
    }
  }

  Future<void> cancelSignIn() => GitHubAuthService.instance.cancelSignIn();

  /// 退出登录
  Future<void> signOut() async {
    await GitHubAuthService.instance.clearToken();
    _token = null;
    _user = null;
    _status = GitHubAuthStatus.signedOut;
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
    // 同步到项目历史，供云端持久化
    await ProjectHistoryService.instance.setRepo(
      projectPath,
      repoFullName: repoFullName,
      host: 'github',
    );
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

  /// 为项目创建 GitHub 仓库并建立映射
  Future<GitHubRepo> createRepoForProject(
    String projectPath,
    String repoName, {
    bool private = true,
  }) async {
    final client = api;
    if (client == null) throw StateError(t('github.error.notSignedIn'));
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
    if (client == null || login == null) {
      throw StateError(t('github.error.notSignedIn'));
    }
    for (var i = 0; i <= 20; i++) {
      final candidate = i == 0 ? baseName : '${baseName}_$i';
      try {
        final exists = await client.getRepo('$login/$candidate');
        if (exists == null) return candidate;
      } on HttpExceptionWithBody catch (e) {
        // 409/422 等无法确认是否存在的状态：不再继续探测，交由创建时重试
        final ambiguous =
            e.message.contains('HTTP 409') || e.message.contains('HTTP 422');
        if (ambiguous) return candidate;
        rethrow;
      }
    }
    throw StateError(t('github.error.tooManyDuplicates'));
  }

  /// 创建仓库并把整个项目（含构建 workflow）首次推送到 main 分支
  ///
  /// 返回创建的仓库。若仓库已存在（同名）会自动追加 _1、_2。
  Future<GitHubRepo> createRepoWithInitialPush(
    String projectPath,
    String repoName, {
    bool private = true,
    void Function(String line)? onLog,
  }) async {
    final client = api;
    if (client == null) throw StateError(t('github.error.notSignedIn'));

    // GitHub 仓库名只允许字母/数字/_/-/.，中文名需先清洗
    final safeName = sanitizeRepoName(repoName);
    if (safeName != repoName) {
      onLog?.call(t('github.log.nameSanitized', {
        'name': repoName,
        'safeName': safeName,
      }));
    }
    final resolvedName = await uniqueRepoName(safeName);
    if (resolvedName != safeName) {
      onLog?.call(t('github.log.repoExists', {
        'name': safeName,
        'resolved': resolvedName,
      }));
    }

    onLog?.call(t('github.log.creatingRepo', {'name': resolvedName}));
    GitHubRepo? repo;
    var attemptName = resolvedName;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        repo = await createRepoForProject(
          projectPath,
          attemptName,
          private: private,
        );
        break;
      } on HttpExceptionWithBody catch (e) {
        // 422/409：仓库名已被占用或创建中，换一个带时间后缀的名字重试
        final retryable =
            e.message.contains('HTTP 422') || e.message.contains('HTTP 409');
        if (!retryable || attempt == 3) rethrow;
        attemptName =
            '${safeName}_${DateTime.now().millisecondsSinceEpoch % 10000}';
        onLog?.call(t('github.log.repoConflictRetry', {'name': attemptName}));
      }
    }
    if (repo == null) throw StateError(t('github.error.createFailed'));
    onLog?.call('    ${repo.htmlUrl}');

    onLog?.call(t('github.log.scanningFiles'));
    final files = await ProjectSnapshot.collect(
      projectPath,
      onSkip: (path) => onLog?.call(t('github.log.skipped', {'path': path})),
    );
    onLog?.call(t('github.log.fileCount', {'count': '${files.length}'}));

    onLog?.call(t('github.log.pushingInitial'));
    await client.pushFiles(
      repo.fullName,
      files,
      message: 'chore: initial commit from SLIPE',
      branch: repo.defaultBranch,
    );

    // 按项目载荷推送对应的构建 workflow
    final payload = await PayloadRegistry.detect(projectPath);
    if (!await client.fileExists(
      repo.fullName,
      payload.workflowPath,
      repo.defaultBranch,
    )) {
      onLog?.call(t('github.log.pushingWorkflow', {'payload': payload.name}));
      await BuildService.instance.ensureWorkflow(
        client,
        repo.fullName,
        branch: repo.defaultBranch,
        path: payload.workflowPath,
        content: payload.workflowContent,
      );
    }
    onLog?.call(t('github.log.done'));
    return repo;
  }
}
