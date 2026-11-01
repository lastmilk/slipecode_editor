import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project.dart';

/// 项目历史记录服务
///
/// 记录创建/打开过的项目（去重，按最近使用时间排序），
/// 用 SharedPreferences 持久化。
class ProjectHistoryService {
  ProjectHistoryService._();

  static final ProjectHistoryService instance = ProjectHistoryService._();

  static const _key = 'slipe_project_history';
  static const _maxEntries = 30;

  /// 读取历史记录（按最近编辑时间倒序）
  Future<List<Project>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final items = (jsonDecode(raw) as List)
          .map((e) => Project.fromMap(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.activityAt.compareTo(a.activityAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  /// 最近编辑的项目（无历史时为 null）
  Future<Project?> lastEdited() async {
    final items = await list();
    return items.isEmpty ? null : items.first;
  }

  /// 记录一次创建/打开（同路径去重并置顶，刷新最近编辑时间）
  Future<void> touch(String path, {String? name}) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    final existing = items.where((e) => e.path == path).firstOrNull;
    items.removeWhere((e) => e.path == path);
    final now = DateTime.now();
    items.insert(
      0,
      Project(
        name: name ?? existing?.name ?? _nameFromPath(path),
        path: path,
        createdAt: existing?.createdAt ?? now,
        lastEditedAt: now,
        repoFullName: existing?.repoFullName,
        host: existing?.host,
      ),
    );
    if (items.length > _maxEntries) {
      items.removeRange(_maxEntries, items.length);
    }
    await _save(prefs, items);
  }

  /// 记录项目关联的远程仓库（用于云端同步）
  Future<void> setRepo(String path, {String? repoFullName, String? host}) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    final index = items.indexWhere((e) => e.path == path);
    if (index == -1) return;
    items[index] = items[index].copyWith(
      repoFullName: repoFullName,
      host: host,
    );
    await _save(prefs, items);
  }

  /// 合并云端项目列表（本地优先，云端补缺；不存在的路径标记 missing）
  Future<List<Project>> mergeCloud(
    List<Project> cloud, {
    bool Function(String path)? existsOnDevice,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final local = await list();
    final merged = <String, Project>{
      for (final item in local) item.path: item,
    };
    for (final remote in cloud) {
      final current = merged[remote.path];
      if (current == null) {
        final exists = existsOnDevice?.call(remote.path) ?? true;
        merged[remote.path] = remote.copyWith(missing: !exists);
      } else {
        merged[remote.path] = current.copyWith(
          repoFullName: remote.repoFullName ?? current.repoFullName,
          host: remote.host ?? current.host,
          lastEditedAt: remote.lastEditedAt ?? current.lastEditedAt,
        );
      }
    }
    final items = merged.values.toList()
      ..sort((a, b) => b.activityAt.compareTo(a.activityAt));
    if (items.length > _maxEntries) {
      items.removeRange(_maxEntries, items.length);
    }
    await _save(prefs, items);
    return items;
  }

  /// 删除一条记录
  Future<void> remove(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.path == path);
    await _save(prefs, items);
  }

  Future<void> _save(SharedPreferences prefs, List<Project> items) async {
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
  }

  static String _nameFromPath(String path) {
    final trimmed = path.replaceAll(RegExp(r'[/\\]+$'), '');
    final segments = trimmed.split(RegExp(r'[/\\]'));
    return segments.isEmpty ? trimmed : segments.last;
  }
}
