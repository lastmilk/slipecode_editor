import 'dart:convert';
import 'dart:io';

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

  /// 供 Android 系统悬浮球面板读取的项目列表（JSON）
  static const overlayProjectsKey = 'slipe_overlay_projects';

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
  Future<void> touch(String path, {String? name, String? kind}) async {
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
        kind: kind ?? existing?.kind ?? 'classic',
      ),
    );
    if (items.length > _maxEntries) {
      items.removeRange(_maxEntries, items.length);
    }
    await _save(prefs, items);
  }

  /// 修正历史记录中的项目类型（Loader 项目由 .slipe.json 判定）
  Future<void> setKind(String path, String kind) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    final index = items.indexWhere((e) => e.path == path);
    if (index == -1) return;
    items[index] = items[index].copyWith(kind: kind);
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

  /// 删除一条记录
  Future<void> remove(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.path == path);
    await _save(prefs, items);
  }

  /// 把项目列表写入 SharedPreferences，供 Android 系统悬浮球面板选择项目
  Future<void> publishOverlayProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    final overlay = <Map<String, String>>[
      for (final project in items)
        if (Directory(project.path).existsSync())
          {'name': project.name, 'path': project.path},
    ];
    await prefs.setString(overlayProjectsKey, jsonEncode(overlay));
  }

  Future<void> _save(SharedPreferences prefs, List<Project> items) async {
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
    // 同步给系统悬浮球的轻量面板
    await publishOverlayProjects();
  }

  static String _nameFromPath(String path) {
    final trimmed = path.replaceAll(RegExp(r'[/\\]+$'), '');
    final segments = trimmed.split(RegExp(r'[/\\]'));
    return segments.isEmpty ? trimmed : segments.last;
  }
}
