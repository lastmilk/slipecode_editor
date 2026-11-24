import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../payloads/project_payload.dart';
import '../services/gitee_api_service.dart';
import '../services/gitee_auth_service.dart';
import '../services/gitee_go_templates.dart';
import '../services/git_host.dart';
import '../services/project_history_service.dart';
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
  String? _grantedScope;
  DateTime? _expiresAt;

  /// projectPath → repoFullName
  final Map<String, String> _repoMap = {};

  GiteeAuthStatus get status => _status;
  GiteeUser? get user => _user;
  String? get error => _error;
  String? get grantedScope => _grantedScope;
  DateTime? get expiresAt => _expiresAt;

  /// 当前已保存的 access token（仓库拉取需要用它做 HTTPS 认证）
  String? get token => _token;

  bool get isConfigured => AppConfig.isGiteeConfigured;
  bool get isSignedIn => _status == GiteeAuthStatus.signedIn && _token != null;

  GiteeApiService? get api => isSignedIn ? GiteeApiService(_token!) : null;

  static const _repoMapPrefix = 'slipe_gitee_repo::';

  /// 启动时恢复登录状态
  Future<void> init() async {
    await _loadRepoMap();
    final token = await GiteeAuthService.instance.validToken();
    _grantedScope = await GiteeAuthService.instance.savedScope;
    _expiresAt = await GiteeAuthService.instance.savedExpiry;
    if (token == null || token.isEmpty) {
      _grantedScope = null;
      _expiresAt = null;
      _status = GiteeAuthStatus.signedOut;
      notifyListeners();
      return;
    }
    _token = token;
    // 校验通过后再标记为已登录，避免显示旧账号信息
    _status = GiteeAuthStatus.unknown;
    notifyListeners();
    // 校验 token；网络不可达时降级为未登录，但保留 token 以便下次重试
    try {
      final user = await GiteeApiService(token)
          .getAuthenticatedUser()
          .timeout(const Duration(seconds: 10));
      _assertGiteeAccount(user);
      _user = user;
      _status = GiteeAuthStatus.signedIn;
    } catch (e) {
      debugPrint('Gitee token 校验失败：$e');
      final isNetworkError = e is TimeoutException || e is SocketException;
      if (!isNetworkError) {
        await GiteeAuthService.instance.clearToken();
        _token = null;
        _grantedScope = null;
        _expiresAt = null;
      }
      _status = GiteeAuthStatus.signedOut;
      _user = null;
    }
    notifyListeners();
  }

  /// 发起 Gitee OAuth 登录（授权码由后端换取 token）
  Future<bool> signIn() async {
    if (!isConfigured) {
      _error = t('gitee.error.notConfigured');
      notifyListeners();
      return false;
    }
    _status = GiteeAuthStatus.signingIn;
    _error = null;
    notifyListeners();
    try {
      final result = await GiteeAuthService.instance.signIn();
      _token = result.accessToken;
      _grantedScope = result.scope;
      _expiresAt = result.expiresAt;
      // 此时 _status 仍为 signingIn，api getter 会返回 null，必须直接构造客户端。
      final user = await GiteeApiService(result.accessToken)
          .getAuthenticatedUser()
          .timeout(const Duration(seconds: 15));
      // 防止 OAuth 回调/后端配置串台：拿到非 Gitee 账号时拒绝登录。
      _assertGiteeAccount(user);
      _user = user;
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

  /// 校验授权结果确实是 Gitee 账号
  void _assertGiteeAccount(GiteeUser user) {
    final login = user.login.trim();
    final htmlUrl = user.htmlUrl.trim().toLowerCase();
    if (login.isEmpty || !htmlUrl.contains('gitee.com')) {
      throw StateError('Gitee 授权返回的不是 Gitee 账号（$login），请检查 OAuth 配置');
    }
  }

  Future<void> cancelSignIn() => GiteeAuthService.instance.cancelSignIn();

  Future<void> signOut() async {
    await GiteeAuthService.instance.clearToken();
    _token = null;
    _grantedScope = null;
    _expiresAt = null;
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
    await ProjectHistoryService.instance.setRepo(
      projectPath,
      repoFullName: repoFullName,
      host: 'gitee',
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

  /// 为项目创建 Gitee 仓库并建立映射
  Future<GiteeRepo> createRepoForProject(
    String projectPath,
    String repoName, {
    bool private = true,
  }) async {
    final client = api;
    if (client == null) throw StateError(t('gitee.error.notSignedIn'));
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
      throw StateError(t('gitee.error.notSignedIn'));
    }
    for (var i = 0; i <= 20; i++) {
      final candidate = i == 0 ? baseName : '${baseName}_$i';
      final exists = await client.getRepo('$login/$candidate');
      if (exists == null) return candidate;
    }
    throw StateError(t('gitee.error.tooManyDuplicates'));
  }

  /// 创建仓库并把整个项目（含 Gitee Go 流水线）首次推送到默认分支
  Future<GiteeRepo> createRepoWithInitialPush(
    String projectPath,
    String repoName, {
    bool private = true,
    void Function(String line)? onLog,
  }) async {
    final client = api;
    if (client == null) throw StateError(t('gitee.error.notSignedIn'));

    // Gitee 仓库名只允许字母/数字/_/-/.,中文名需先清洗，否则服务端 400
    final safeName = sanitizeRepoName(repoName);
    if (safeName != repoName) {
      onLog?.call(
        t('gitee.log.nameSanitized', {'name': repoName, 'safeName': safeName}),
      );
    }
    final resolvedName = await uniqueRepoName(safeName);
    if (resolvedName != safeName) {
      onLog?.call(
        t('gitee.log.repoExists', {'name': safeName, 'resolved': resolvedName}),
      );
    }

    onLog?.call(t('gitee.log.creatingRepo', {'name': resolvedName}));
    final repo = await createRepoForProject(
      projectPath,
      resolvedName,
      private: private,
    );
    onLog?.call('    ${repo.htmlUrl}');

    // 新仓库必须先开通 Gitee Go，.workflow 流水线才会被识别
    // POST /v5/repos/{owner}/{repo}/open（幂等，已开通同样返回成功）
    try {
      onLog?.call(t('gitee.log.openingGiteeGo'));
      await client.openGiteeGo(repo.fullName);
      onLog?.call(t('gitee.log.giteeGoOpened'));
    } catch (e) {
      // 开通失败不阻断建仓：仓库本身可用，稍后构建时还会重试开通
      onLog?.call(t('gitee.log.giteeGoOpenFailed', {'error': '$e'}));
    }

    onLog?.call(t('gitee.log.scanningFiles'));
    final files = await ProjectSnapshot.collect(
      projectPath,
      onSkip: (path) => onLog?.call(t('gitee.log.skipped', {'path': path})),
    );
    onLog?.call(t('gitee.log.fileCount', {'count': '${files.length}'}));

    onLog?.call(t('gitee.log.pushingInitial'));
    await client.pushFiles(
      repo.fullName,
      files,
      message: 'chore: initial commit from SLIPE',
      branch: repo.defaultBranch,
      onProgress: (done, total) {
        if (done == total || done % 10 == 0) {
          onLog?.call(
            t('gitee.log.pushProgress', {'done': '$done', 'total': '$total'}),
          );
        }
      },
    );

    // Gitee Go 目前只有 Flutter 流水线，其它载荷不推送
    final payload = await PayloadRegistry.detect(projectPath);
    if (payload.supportsGitee &&
        !await client.fileExists(
          repo.fullName,
          GiteeGoTemplates.workflowPath,
          repo.defaultBranch,
        )) {
      onLog?.call(t('gitee.log.pushingPipeline'));
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
      onLog?.call(t('gitee.log.noMacRunnerHint'));
    }
    onLog?.call(t('gitee.log.done'));
    return repo;
  }
}
