import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/github_api_service.dart' show RepoFile;
import '../services/git_host.dart';
import '../services/project_snapshot.dart';
import 'gitee_provider.dart';
import 'github_provider.dart';
import 'project_provider.dart';

/// 同步状态
enum GitSyncStatus { idle, pending, syncing, success, error }

/// 项目关联的远程仓库
class GitLink {
  final GitHost host;
  final String repo;

  const GitLink(this.host, this.repo);
}

/// 代码自动同步（AI 自动 push）
///
/// 编辑器保存文件后调用 [markChanged]，防抖后自动把变更文件推送到
/// GitHub 或 Gitee（取决于项目关联的仓库）。
class GitSyncProvider extends ChangeNotifier {
  GitSyncProvider(this._github, this._gitee, this._project);

  final GitHubProvider _github;
  final GiteeProvider _gitee;
  final ProjectProvider _project;

  static const Duration debounce = Duration(seconds: 8);

  /// 每次自动推送的最大文件数（防御性限制）
  static const int maxFilesPerPush = 200;

  /// 单文件大小上限
  static const int maxFileBytes = 5 * 1024 * 1024;

  GitSyncStatus _status = GitSyncStatus.idle;
  final Set<String> _pending = {};
  Timer? _timer;
  String? _error;
  DateTime? _lastSyncAt;
  String _lastCommitUrl = '';

  GitSyncStatus get status => _status;
  int get pendingCount => _pending.length;
  String? get error => _error;
  DateTime? get lastSyncAt => _lastSyncAt;
  String get lastCommitUrl => _lastCommitUrl;

  /// 当前项目关联的远程仓库（优先 GitHub，其次 Gitee）
  GitLink? get currentLink {
    final path = _project.projectPath;
    if (path == null) return null;
    return linkFor(path);
  }

  GitLink? linkFor(String projectPath) {
    final githubRepo = _github.repoFor(projectPath);
    if (githubRepo != null) return GitLink(GitHost.github, githubRepo);
    final giteeRepo = _gitee.repoFor(projectPath);
    if (giteeRepo != null) return GitLink(GitHost.gitee, giteeRepo);
    return null;
  }

  bool _hostSignedIn(GitHost host) => switch (host) {
        GitHost.github => _github.isSignedIn,
        GitHost.gitee => _gitee.isSignedIn,
      };

  /// 是否具备同步条件（对应平台已登录 + 项目已关联仓库）
  bool get canSync {
    final link = currentLink;
    return link != null && _hostSignedIn(link.host);
  }

  /// 标记文件已变更（保存后由编辑器调用）
  void markChanged(String filePath) {
    if (!canSync) return;
    _pending.add(filePath);
    _status = GitSyncStatus.pending;
    _timer?.cancel();
    _timer = Timer(debounce, syncNow);
    notifyListeners();
  }

  /// 立即同步所有待推送文件
  Future<bool> syncNow() async {
    _timer?.cancel();
    if (_status == GitSyncStatus.syncing) return false;
    if (_pending.isEmpty) {
      _status = GitSyncStatus.idle;
      notifyListeners();
      return true;
    }
    final projectPath = _project.projectPath;
    final link = projectPath == null ? null : linkFor(projectPath);
    if (projectPath == null || link == null || !_hostSignedIn(link.host)) {
      _pending.clear();
      _status = GitSyncStatus.idle;
      notifyListeners();
      return false;
    }

    final files = _pending.toList();
    _status = GitSyncStatus.syncing;
    _error = null;
    notifyListeners();

    try {
      final repoFiles = <RepoFile>[];
      for (final path in files) {
        final file = File(path);
        if (!await file.exists()) continue; // 已删除的文件跳过（暂不支持删除）
        final relative = p.relative(path, from: projectPath);
        final repoPath = relative.replaceAll(Platform.pathSeparator, '/');
        final bytes = await file.readAsBytes();
        if (bytes.length > maxFileBytes) continue;
        repoFiles.add(RepoFile(
          repoPath,
          bytes,
          isText: !ProjectSnapshot.looksBinary(repoPath),
        ));
        if (repoFiles.length >= maxFilesPerPush) break;
      }

      if (repoFiles.isEmpty) {
        _pending.clear();
        _status = GitSyncStatus.idle;
        notifyListeners();
        return true;
      }

      final result = switch (link.host) {
        GitHost.github => await _github.api!.pushFiles(
            link.repo,
            repoFiles,
            message: 'chore: sync ${repoFiles.length} file(s) from SlipCode',
          ),
        GitHost.gitee => await _gitee.api!.pushFiles(
            link.repo,
            repoFiles,
            message: 'chore: sync ${repoFiles.length} file(s) from SlipCode',
            branch: 'master',
          ),
      };

      _pending.removeAll(files);
      _lastSyncAt = DateTime.now();
      _lastCommitUrl = result.commitUrl;
      _status = _pending.isEmpty ? GitSyncStatus.success : GitSyncStatus.pending;
      notifyListeners();

      // 若因 maxFilesPerPush 截断还有剩余，继续同步
      if (_pending.isNotEmpty) {
        _timer = Timer(const Duration(seconds: 1), syncNow);
      }
      return true;
    } catch (e) {
      _error = '$e';
      _status = GitSyncStatus.error;
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
