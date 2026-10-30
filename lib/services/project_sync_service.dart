import 'dart:async';
import 'dart:io';

import '../models/app_settings.dart';
import '../models/project.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import 'account_service.dart';
import 'network_policy.dart';
import 'project_history_service.dart';

/// 项目列表云同步
///
/// 云端保存「本地打开过的项目路径 + git 远程仓库」，
/// 登录后在允许的网络下自动合并恢复；设备上不存在的路径只做标记，不删除。
class ProjectSyncService {
  ProjectSyncService._();

  static final ProjectSyncService instance = ProjectSyncService._();

  Timer? _debounce;

  /// 打开/关闭项目后延迟同步（避免频繁请求）
  void schedule({void Function()? onDone}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      onDone?.call();
    });
  }

  void cancel() {
    _debounce?.cancel();
    _debounce = null;
  }

  /// 执行一次双向同步；返回合并后的本地列表
  Future<List<Project>> sync({
    required String token,
    required AppSettings settings,
    GitHubProvider? github,
    GiteeProvider? gitee,
  }) async {
    if (!await NetworkPolicy.canSyncNow(settings)) {
      return ProjectHistoryService.instance.list();
    }

    final history = await ProjectHistoryService.instance.list();
    final local = history.map((project) {
      final repo = github?.repoFor(project.path);
      if (repo != null) {
        return project.copyWith(repoFullName: repo, host: 'github');
      }
      final giteeRepo = gitee?.repoFor(project.path);
      if (giteeRepo != null) {
        return project.copyWith(repoFullName: giteeRepo, host: 'gitee');
      }
      return project;
    }).toList();

    final remoteRaw = await AccountService.instance.fetchProjects(token);
    final remote = <Project>[];
    for (final item in remoteRaw) {
      final path = (item['path'] ?? '').toString();
      if (path.isEmpty) continue;
      final lastEdited = DateTime.tryParse(
        (item['lastEditedAt'] ?? '').toString(),
      );
      remote.add(
        Project(
          name: (item['name'] ?? '').toString().isEmpty
              ? path
              : item['name'].toString(),
          path: path,
          createdAt: lastEdited ?? DateTime.now(),
          lastEditedAt: lastEdited,
          repoFullName: item['repoFullName'] as String?,
          host: item['host'] as String?,
        ),
      );
    }

    // 先把本地状态写回云端（保证本机路径不丢），再合并云端补缺
    await AccountService.instance.pushProjects(
      token,
      local
          .map((project) => {
                'path': project.path,
                'name': project.name,
                'repoFullName': project.repoFullName,
                'host': project.host,
                'lastEditedAt': project.lastEditedAt?.toIso8601String(),
              })
          .toList(),
    );

    final merged = await ProjectHistoryService.instance.mergeCloud(
      remote,
      existsOnDevice: (path) => Directory(path).existsSync(),
    );

    // 回填仓库映射，供 Git 同步/构建使用
    for (final project in merged) {
      final repo = project.repoFullName;
      if (repo == null || repo.isEmpty) continue;
      if (project.host == 'gitee') {
        await gitee?.linkRepo(project.path, repo);
      } else {
        await github?.linkRepo(project.path, repo);
      }
    }
    return merged;
  }
}
