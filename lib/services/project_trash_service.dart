import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/project.dart';

/// 回收站中的项目（删除后可还原）
class TrashedProject {
  final String id;
  final String name;
  final String originalPath;
  final String trashPath;
  final String kind;
  final DateTime deletedAt;

  const TrashedProject({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.trashPath,
    required this.kind,
    required this.deletedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'originalPath': originalPath,
        'trashPath': trashPath,
        'kind': kind,
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory TrashedProject.fromMap(Map<String, dynamic> map) => TrashedProject(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        originalPath: (map['originalPath'] ?? '').toString(),
        trashPath: (map['trashPath'] ?? '').toString(),
        kind: (map['kind'] ?? 'classic').toString(),
        deletedAt:
            DateTime.tryParse((map['deletedAt'] ?? '').toString()) ??
                DateTime.now(),
      );
}

/// 项目回收站
///
/// 删除项目时把磁盘目录移动到应用私有回收站（而不是只删历史记录），
/// 原始路径随即从磁盘消失；需要时可以还原回原路径。
class ProjectTrashService {
  ProjectTrashService._();

  static final ProjectTrashService instance = ProjectTrashService._();

  static const _key = 'slipe_trashed_projects';

  Future<Directory> _trashRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'trash'));
  }

  Future<List<TrashedProject>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final items = (jsonDecode(raw) as List)
          .map((e) => TrashedProject.fromMap(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      return items.where((e) => Directory(e.trashPath).existsSync()).toList();
    } catch (_) {
      return [];
    }
  }

  /// 把项目目录移动到回收站
  Future<bool> moveToTrash(Project project) async {
    final source = Directory(project.path);
    if (!source.existsSync()) return false;
    final root = await _trashRoot();
    await root.create(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final dest = p.join(root.path, id);
    try {
      await source.rename(dest);
    } catch (_) {
      // 跨文件系统时 rename 会失败：退化为复制后删除
      await _copyDirectory(source, Directory(dest));
      await source.delete(recursive: true);
    }

    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.insert(
      0,
      TrashedProject(
        id: id,
        name: project.name,
        originalPath: project.path,
        trashPath: dest,
        kind: project.kind,
        deletedAt: DateTime.now(),
      ),
    );
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
    return true;
  }

  /// 还原到原始路径；原路径被占用时自动追加 _1、_2 后缀
  Future<String?> restore(TrashedProject entry) async {
    final source = Directory(entry.trashPath);
    if (!source.existsSync()) return null;
    var target = entry.originalPath;
    var index = 1;
    while (Directory(target).existsSync() || File(target).existsSync()) {
      target = '${entry.originalPath}_$index';
      index += 1;
    }
    final parent = Directory(p.dirname(target));
    await parent.create(recursive: true);
    try {
      await source.rename(target);
    } catch (_) {
      await _copyDirectory(source, Directory(target));
      await source.delete(recursive: true);
    }

    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    items.removeWhere((e) => e.id == entry.id);
    await prefs.setString(
      _key,
      jsonEncode(items.map((e) => e.toMap()).toList()),
    );
    return target;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(target.path, name)));
      } else if (entity is File) {
        await entity.copy(p.join(target.path, name));
      }
    }
  }
}
