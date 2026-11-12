import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project.dart';

/// 一条「仅从列表移除」的项目记录（磁盘文件仍然保留）
class RemovedProject {
  final String id;
  final String name;
  final String path;
  final String kind;
  final DateTime removedAt;

  const RemovedProject({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.removedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'path': path,
        'kind': kind,
        'removedAt': removedAt.toIso8601String(),
      };

  factory RemovedProject.fromMap(Map<String, dynamic> map) => RemovedProject(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        path: (map['path'] ?? '').toString(),
        kind: (map['kind'] ?? 'classic').toString(),
        removedAt:
            DateTime.tryParse((map['removedAt'] ?? '').toString()) ??
                DateTime.now(),
      );
}

/// 项目列表回收站
///
/// 只记录「从列表移除但磁盘仍保留」的项目，用于还原到首页列表。
/// 真正的磁盘删除是永久性的，不经过这里。
class ProjectTrashService {
  ProjectTrashService._();

  static final ProjectTrashService instance = ProjectTrashService._();

  static const _key = 'slipe_removed_projects';

  Future<List<RemovedProject>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final items = (jsonDecode(raw) as List)
          .map((e) => RemovedProject.fromMap(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.removedAt.compareTo(a.removedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  /// 仅可还原磁盘上仍存在的项目
  Future<List<RemovedProject>> listRestorable() async {
    final items = await list();
    return items.where((e) => Directory(e.path).existsSync()).toList();
  }

  /// 记录一次「仅从列表移除」
  Future<void> rememberRemoved(Project project) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.path == project.path);
    items.insert(
      0,
      RemovedProject(
        id: 'rm_${DateTime.now().microsecondsSinceEpoch}',
        name: project.name,
        path: project.path,
        kind: project.kind,
        removedAt: DateTime.now(),
      ),
    );
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
  }

  /// 还原：只从回收记录中移除，磁盘文件一直保留在原路径
  Future<bool> restore(RemovedProject entry) async {
    if (!Directory(entry.path).existsSync()) return false;
    await forget(entry.id);
    return true;
  }

  /// 永久删除项目后清理对应记录
  Future<void> forget(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
  }

  /// 按路径清理（永久删除时调用）
  Future<void> forgetPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.path == path);
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
  }
}
