import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/build_service.dart';
import '../services/github_api_service.dart';
import '../services/github_auth_service.dart';
import '../services/project_snapshot.dart';

/// GitHub 授权状态
enum GitHubAuthStatus { unknown, signedOut, signingIn, signedIn }

/// GitHub 账号与仓库状态管理
///
/// - 维护 OAuth(PKCE) 登录状态与 token 持久化
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

  /// 已登录时返回 API 客户端
  GitHubApiService? get api =>
      isSignedIn ? GitHubApiService(_token!) : null;

  static const _repoMapPrefix = 'slipecode_repo::';

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
    _status = GitHubAuthStatus.signedIn;
    notifyListeners();
    // 校验 token 并拉取用户信息（失败则说明 token 已失效）
    try {
      _user = await api!.getAuthenticatedUser();
    } catch (e) {
      debugPrint('GitHub token 校验失败：$e');
      await GitHubAuthService.instance.clearToken();
      _token = null;
      _status = GitHubAuthStatus.signedOut;
    }
    notifyListeners();
  }

  /// 发起 OAuth(PKCE) 登录
  Future<bool> signIn() async {
    if (!isConfigured) {
      _error = '未配置 GITHUB_CLIENT_ID，请先在 .env 中填写后重启应用';
      notifyListeners();
      return false;
    }
    _status = GitHubAuthStatus.signingIn;
    _error = null;
    notifyListeners();
    try {
      final result = await GitHubAuthService.instance.signIn();
      _token = result.accessToken;
      _user = await api!.getAuthenticatedUser();
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
    if (client == null) throw StateError('尚未登录 GitHub');
    final repo = await client.createRepo(
      repoName,
      private: private,
      description: 'Created by SlipCode',
    );
    await linkRepo(projectPath, repo.fullName);
    return repo;
  }

  /// 创建仓库并把整个项目（含构建 workflow）首次推送到 main 分支
  ///
  /// 返回创建的仓库。若仓库已存在（同名）会抛出异常。
  Future<GitHubRepo> createRepoWithInitialPush(
    String projectPath,
    String repoName, {
    bool private = true,
    void Function(String line)? onLog,
  }) async {
    final client = api;
    if (client == null) throw StateError('尚未登录 GitHub');

    onLog?.call('==> 创建 GitHub 仓库：$repoName');
    final repo = await createRepoForProject(
      projectPath,
      repoName,
      private: private,
    );
    onLog?.call('    ${repo.htmlUrl}');

    onLog?.call('==> 扫描项目文件');
    final files = await ProjectSnapshot.collect(
      projectPath,
      onSkip: (path) => onLog?.call('    跳过：$path'),
    );
    onLog?.call('    共 ${files.length} 个文件');

    onLog?.call('==> 推送初始代码到 main 分支');
    await client.pushFiles(
      repo.fullName,
      files,
      message: 'chore: initial commit from SlipCode',
      branch: repo.defaultBranch,
    );

    if (!await client.fileExists(
        repo.fullName, BuildService.workflowFile, repo.defaultBranch)) {
      onLog?.call('==> 推送 GitHub Actions 构建 workflow');
      await BuildService.instance.ensureWorkflow(
        client,
        repo.fullName,
        branch: repo.defaultBranch,
      );
    }
    onLog?.call('==> 完成');
    return repo;
  }
}
