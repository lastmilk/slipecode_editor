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

  static const _key = 'slipecode_project_history';
  static const _maxEntries = 30;

  /// 读取历史记录（按最近使用时间倒序）
  Future<List<Project>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final items = (jsonDecode(raw) as List)
          .map((e) => Project.fromMap(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  /// 记录一次创建/打开（同路径去重并置顶）
  Future<void> touch(String path, {String? name}) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.path == path);
    items.insert(
      0,
      Project(
        name: name ?? _nameFromPath(path),
        path: path,
        createdAt: DateTime.now(),
      ),
    );
    if (items.length > _maxEntries) {
      items.removeRange(_maxEntries, items.length);
    }
    await _save(prefs, items);
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
