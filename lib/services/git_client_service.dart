import 'dart:io';

import 'package:flutter/services.dart';
import 'package:git2dart/git2dart.dart';
import 'package:path/path.dart' as p;

import '../models/sync_repo.dart';
import 'git_host.dart';

class GitSyncException implements Exception {
  GitSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitSyncOutcome {
  const GitSyncOutcome({required this.path, required this.cloned});

  final String path;

  /// true = 新建克隆，false = 已有仓库增量拉取
  final bool cloned;
}

/// 本地 Git 仓库拉取。
///
/// - Android：通过平台通道调用 JGit（org.eclipse.jgit）执行 clone / pull；
/// - iOS：使用 git2dart（libgit2）执行 clone / fetch + hard reset；
/// - 桌面端同样走 libgit2，方便调试。
class GitClientService {
  GitClientService._();

  static final GitClientService instance = GitClientService._();

  static const MethodChannel _channel = MethodChannel('slipe/git');

  Future<GitSyncOutcome> syncRepo(
    SyncRepo repo, {
    required String destPath,
    required String username,
    required String token,
  }) async {
    if (Platform.isAndroid) {
      return _syncWithJGit(
        repo,
        destPath: destPath,
        username: username,
        token: token,
      );
    }
    return _syncWithLibgit2(
      repo,
      destPath: destPath,
      username: username,
      token: token,
    );
  }

  Future<GitSyncOutcome> _syncWithJGit(
    SyncRepo repo, {
    required String destPath,
    required String username,
    required String token,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'cloneOrPull',
        {
          'url': repo.cloneUrl,
          'destPath': destPath,
          'branch': repo.defaultBranch,
          'username': username,
          'token': token,
        },
      );
      return GitSyncOutcome(
        path: destPath,
        cloned: (result?['cloned'] as bool?) ?? false,
      );
    } on PlatformException catch (e) {
      throw GitSyncException(e.message ?? 'Git 操作失败（${e.code}）');
    } on MissingPluginException {
      throw GitSyncException('当前客户端未集成 JGit，无法拉取仓库');
    }
  }

  Future<GitSyncOutcome> _syncWithLibgit2(
    SyncRepo repo, {
    required String destPath,
    required String username,
    required String token,
  }) async {
    final callbacks = Callbacks(
      credentials: UserPass(username: username, password: token),
    );
    final gitDir = Directory(p.join(destPath, '.git'));
    final parent = Directory(destPath).parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);

    try {
      if (gitDir.existsSync()) {
        final repository = Repository.open(destPath);
        try {
          final origin = Remote.lookup(repo: repository, name: 'origin');
          origin.fetch(
            refspecs: [
              '+refs/heads/${repo.defaultBranch}:'
                  'refs/remotes/origin/${repo.defaultBranch}',
            ],
            callbacks: callbacks,
          );
          final target = RevParse.single(
            repo: repository,
            spec: 'origin/${repo.defaultBranch}',
          );
          if (target is! Commit) {
            throw GitSyncException('找不到远程分支 ${repo.defaultBranch}');
          }
          repository.reset(oid: target.oid, resetType: GitReset.hard);
        } finally {
          repository.free();
        }
        return GitSyncOutcome(path: destPath, cloned: false);
      }

      final dir = Directory(destPath);
      if (dir.existsSync()) {
        if (dir.listSync().isNotEmpty) {
          throw GitSyncException('目标目录已存在且不是 Git 仓库：$destPath');
        }
        dir.deleteSync(recursive: true);
      }
      final repository = Repository.clone(
        url: repo.cloneUrl,
        localPath: destPath,
        checkoutBranch: repo.defaultBranch,
        callbacks: callbacks,
      );
      repository.free();
      return GitSyncOutcome(path: destPath, cloned: true);
    } on Git2DartError catch (e) {
      throw GitSyncException('libgit2 拉取失败：${e.message}');
    }
  }

  /// 生成仓库在本地项目目录下的存放路径
  ///
  /// 同名仓库（GitHub / Gitee 可能存在同名项目）自动加平台前缀避免覆盖。
  String resolveDestPath(String projectsRoot, SyncRepo repo) {
    final direct = p.join(projectsRoot, repo.name);
    final gitDir = Directory(p.join(direct, '.git'));
    if (!Directory(direct).existsSync() || gitDir.existsSync()) {
      return direct;
    }
    return p.join(projectsRoot, '${repo.name}_${repo.host.id}');
  }

  /// 仓库认证用户名：
  /// GitHub 的 Personal Access Token 使用 `x-access-token`，
  /// Gitee 官方推荐 `oauth2:<token>` 形式。
  String authUsername(GitHost host) =>
      host == GitHost.github ? 'x-access-token' : 'oauth2';
}
