import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
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

  /// true = 新建下载，false = 已有仓库覆盖更新
  final bool cloned;
}

/// 本地仓库拉取。
///
/// 不再依赖 JGit（Android 上稳定性差、会导致闪退）与 libgit2（原生库），
/// 统一改为通过平台 REST API 下载仓库 Zip 归档并解压：
/// - GitHub：GET /repos/{owner}/{repo}/zipball/{branch}
/// - Gitee：GET /repos/{owner}/{repo}/zipball?ref={branch}
///
/// 应用内的提交推送本来就全部走 REST API（不依赖本地 .git），
/// 因此归档方式对后续「推送 / 构建」链路完全兼容。
class GitClientService {
  GitClientService._();

  static final GitClientService instance = GitClientService._();

  /// 归档体积可能较大，下载给足超时时间
  static const _downloadTimeout = Duration(seconds: 180);

  Future<GitSyncOutcome> syncRepo(
    SyncRepo repo, {
    required String destPath,
    required String token,
  }) async {
    final bytes = await _downloadArchive(repo, token: token);
    final archive = _decodeZip(bytes);
    final existed = Directory(destPath).existsSync();
    await _extractTo(archive, destPath, fullName: repo.fullName);
    return GitSyncOutcome(path: destPath, cloned: !existed);
  }

  // ---------------------------------------------------------------------------
  // 下载
  // ---------------------------------------------------------------------------

  Future<List<int>> _downloadArchive(
    SyncRepo repo, {
    required String token,
  }) async {
    final Uri uri;
    final Map<String, String> headers;
    if (repo.host == GitHost.github) {
      uri = Uri.parse(
        '${AppConfig.apiBase}/repos/${repo.fullName}/zipball/${repo.defaultBranch}',
      );
      headers = {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };
    } else {
      // Gitee OpenAPI v5：GET /repos/{owner}/{repo}/zipball?ref=<分支>
      uri =
          Uri.parse(
            '${AppConfig.giteeApiBase}/repos/${repo.fullName}/zipball',
          ).replace(
            queryParameters: {'access_token': token, 'ref': repo.defaultBranch},
          );
      headers = const {};
    }

    final http.Response res;
    try {
      res = await http
          .get(uri, headers: headers)
          .timeout(_downloadTimeout);
    } catch (e) {
      throw GitSyncException('网络请求失败：$e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw GitSyncException(
        '${repo.host.label} 归档下载失败（HTTP ${res.statusCode}）',
      );
    }
    if (res.bodyBytes.isEmpty) {
      throw GitSyncException('${repo.host.label} 返回了空的归档数据');
    }
    return res.bodyBytes;
  }

  // ---------------------------------------------------------------------------
  // 解压
  // ---------------------------------------------------------------------------

  Archive _decodeZip(List<int> bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw GitSyncException('Zip 归档解析失败：$e');
    }
  }

  /// 把归档内容写入 [destPath]。
  ///
  /// GitHub / Gitee 的仓库 Zip 顶层都有一个形如
  /// `owner-repo-<sha>/` 的目录，解压时剥掉这一层。
  Future<void> _extractTo(
    Archive archive,
    String destPath, {
    required String fullName,
  }) async {
    final dir = Directory(destPath);
    if (await dir.exists()) {
      // 覆盖更新：整目录替换，保证与远端完全一致（远端删掉的文件本地也删除）
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    var written = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final relative = _stripTopLevel(entry.name);
      if (relative == null) continue;
      final outFile = File(p.join(destPath, relative));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      written++;
    }
    if (written == 0) {
      throw GitSyncException('归档中没有任何文件');
    }
    // 写入同步标记：记录该目录是哪个仓库的副本，供 resolveDestPath 判断
    await File(
      p.join(destPath, _syncMarkerName),
    ).writeAsString(fullName, flush: true);
  }

  static const _syncMarkerName = '.slipe_sync';

  /// 剥掉 Zip 顶层目录；返回 null 表示该条目不需要写入
  String? _stripTopLevel(String name) {
    final normalized = name.replaceAll('\\', '/');
    final segments = normalized
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) return null;
    final relative = segments.sublist(1).join('/');
    // 防目录穿越
    if (relative.isEmpty || relative.split('/').contains('..')) return null;
    return relative;
  }

  /// 生成仓库在本地项目目录下的存放路径
  ///
  /// 同名仓库（GitHub / Gitee 可能存在同名项目）自动加平台前缀避免覆盖。
  String resolveDestPath(String projectsRoot, SyncRepo repo) {
    final direct = p.join(projectsRoot, repo.name);
    if (!Directory(direct).existsSync()) {
      return direct;
    }
    // 目录已存在且正是该仓库的同步副本（有同步标记且一致）时原地更新；
    // 否则（本地同名项目）落到带平台后缀的路径，避免误覆盖用户项目。
    try {
      final marker = File(p.join(direct, _syncMarkerName));
      if (marker.existsSync() &&
          marker.readAsStringSync().trim() == repo.fullName) {
        return direct;
      }
    } catch (_) {
      // 读取失败按冲突处理
    }
    return p.join(projectsRoot, '${repo.name}_${repo.host.id}');
  }
}
