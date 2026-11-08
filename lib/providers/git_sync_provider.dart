import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ai_change_journal.dart';
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
      final blocked = <String>[];
      for (final path in files) {
        final file = File(path);
        if (!await file.exists()) continue; // 已删除的文件跳过（暂不支持删除）
        // 未获用户确认的 AI 改动禁止推送到远程仓库
        if (AiChangeJournal.instance.isBlocked(path)) {
          blocked.add(path);
          continue;
        }
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

      if (blocked.isNotEmpty) {
        // 未确认的 AI 改动不推送，等用户确认后再由保存动作重新排队
        _pending.removeAll(blocked);
        _error = '有 ${blocked.length} 个文件因 AI 修改未获批准，已跳过推送';
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
            message: 'chore: sync ${repoFiles.length} file(s) from SLIPE',
          ),
        GitHost.gitee => await _gitee.api!.pushFiles(
            link.repo,
            repoFiles,
            message: 'chore: sync ${repoFiles.length} file(s) from SLIPE',
            branch: 'master',
          ),
      };

      _pending.removeAll(files);
      await _updateManifest(link, {
        for (final file in repoFiles) file.path: _blobSha(file.bytes),
      });
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

  // ---------------------------------------------------------------------------
  // 构建前全量比对（本地 ↔ 远程）
  // ---------------------------------------------------------------------------

  static const String _manifestPrefix = 'slipe_sync_manifest_v1_';

  /// git blob SHA-1：`sha1("blob {长度}\0" + content)`
  ///
  /// GitHub / Gitee 的 tree / contents 接口返回的 sha 均为该算法。
  static String _blobSha(List<int> bytes) {
    final header = utf8.encode('blob ${bytes.length}\u0000');
    return sha1.convert([...header, ...bytes]).toString();
  }

  String _manifestKey(GitLink link) =>
      '$_manifestPrefix${link.host.id}_${link.repo.replaceAll('/', '__')}';

  Future<Map<String, String>> _loadManifest(GitLink link) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_manifestKey(link));
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _updateManifest(
    GitLink link,
    Map<String, String> entries,
  ) async {
    if (entries.isEmpty) return;
    try {
      final manifest = await _loadManifest(link);
      manifest.addAll(entries);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_manifestKey(link), jsonEncode(manifest));
    } catch (e) {
      debugPrint('保存同步清单失败：$e');
    }
  }

  Future<Map<String, String>> _fetchRemoteShas(
    GitLink link,
    List<RepoFile> local,
  ) async {
    switch (link.host) {
      case GitHost.github:
        return await _github.api!.remoteBlobShas(link.repo, 'main');
      case GitHost.gitee:
        return await _gitee.api!.remoteBlobShas(
          link.repo,
          'master',
          local.map((file) => file.path).toList(),
        );
    }
  }

  /// 构建前确保远程仓库与本地完全一致。
  ///
  /// 不依赖「已标记待推送」的文件列表：扫描整个项目，
  /// 与上次同步清单（或远端 tree）比对，把新增 / 修改 / 删除冲突都推上去。
  Future<bool> ensureUpToDate({
    required String projectDir,
    bool approveAiChanges = true,
  }) async {
    if (_status == GitSyncStatus.syncing) {
      // 等待正在进行的自动同步结束，避免与构建推送交错
      for (var i = 0; i < 30 && _status == GitSyncStatus.syncing; i++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (_status == GitSyncStatus.syncing) return false;
    }
    final link = linkFor(projectDir);
    if (link == null || !_hostSignedIn(link.host)) return false;
    final api = link.host == GitHost.github ? _github.api : _gitee.api;
    if (api == null) return false;

    _timer?.cancel();
    _status = GitSyncStatus.syncing;
    _error = null;
    notifyListeners();

    try {
      // 用户点击构建即视为确认当前落盘的 AI 改动
      if (approveAiChanges && AiChangeJournal.instance.hasPending) {
        AiChangeJournal.instance.approveAll();
      }

      final local = await ProjectSnapshot.collect(projectDir);
      final manifest = await _loadManifest(link);
      // GitHub 每次都用远端 tree 做基准（请求成本低且能发现其他设备的提交）；
      // Gitee 逐文件查询成本高，优先使用本地同步清单，首次构建时回源。
      final Map<String, String> baseline;
      if (link.host == GitHost.github || manifest.isEmpty) {
        baseline = await _fetchRemoteShas(link, local);
      } else {
        baseline = manifest;
      }

      final changed = <RepoFile>[];
      for (final file in local) {
        final sha = _blobSha(file.bytes);
        if (baseline[file.path] != sha) changed.add(file);
      }
      if (changed.isEmpty) {
        _pending.clear();
        _lastSyncAt = DateTime.now();
        _status = GitSyncStatus.success;
        notifyListeners();
        return true;
      }

      final branch = link.host == GitHost.github ? 'main' : 'master';
      for (var i = 0; i < changed.length; i += maxFilesPerPush) {
        final end = (i + maxFilesPerPush).clamp(0, changed.length);
        final batch = changed.sublist(i, end);
        final result = switch (link.host) {
          GitHost.github => await _github.api!.pushFiles(
              link.repo,
              batch,
              message: 'chore: sync ${batch.length} file(s) before build',
              branch: branch,
            ),
          GitHost.gitee => await _gitee.api!.pushFiles(
              link.repo,
              batch,
              message: 'chore: sync ${batch.length} file(s) before build',
              branch: branch,
            ),
        };
        _lastCommitUrl = result.commitUrl;
        await _updateManifest(link, {
          for (final file in batch) file.path: _blobSha(file.bytes),
        });
      }

      _pending.clear();
      _lastSyncAt = DateTime.now();
      _status = GitSyncStatus.success;
      _error = '';
      notifyListeners();
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
