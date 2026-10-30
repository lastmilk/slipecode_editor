import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/file_node.dart';

/// 文件系统服务
class FileService {
  /// 需要隐藏的目录/文件名称
  static const Set<String> _hiddenNames = {
    '.git',
    '.idea',
    '.dart_tool',
    'build',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    '.DS_Store',
  };

  /// 从目录路径递归构建文件树
  Future<FileNode> loadDirectory(String path) async {
    final dir = Directory(path);
    final name = path.split(Platform.pathSeparator).last;

    if (!await dir.exists()) {
      return FileNode(name: name, path: path, type: FileNodeType.directory);
    }

    final entities = await dir.list().toList();

    // 排序：目录优先，然后按名称字母排序
    entities.sort((a, b) {
      final aIsDir = a is Directory ? 0 : 1;
      final bIsDir = b is Directory ? 0 : 1;
      if (aIsDir != bIsDir) return aIsDir.compareTo(bIsDir);
      return a.path.split(Platform.pathSeparator).last.toLowerCase().compareTo(
            b.path.split(Platform.pathSeparator).last.toLowerCase(),
          );
    });

    final children = <FileNode>[];
    for (final entity in entities) {
      final nodeName = entity.path.split(Platform.pathSeparator).last;
      // 跳过隐藏项
      if (_hiddenNames.contains(nodeName)) continue;
      if (nodeName.startsWith('.') && nodeName != '.metadata') continue;

      if (entity is Directory) {
        children.add(await loadDirectory(entity.path));
      } else if (entity is File) {
        children.add(
          FileNode(
            name: nodeName,
            path: entity.path,
            type: FileNodeType.file,
          ),
        );
      }
    }

    return FileNode(
      name: name,
      path: path,
      type: FileNodeType.directory,
      children: children,
    );
  }

  /// 读取文件内容
  Future<String> readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File not found: $path');
    }
    // 限制文件大小（1MB）防止大文件卡死
    final stat = await file.stat();
    if (stat.size > 1024 * 1024) {
      throw Exception('File too large (>1MB): $path');
    }
    return await file.readAsString(encoding: utf8);
  }

  /// 保存文件
  Future<void> writeFile(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, encoding: utf8);
  }

  /// 创建新文件
  Future<File> createFile(
    String dirPath,
    String fileName, {
    String content = '',
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dirPath, fileName));
    if (await file.exists()) {
      throw Exception('File already exists: ${file.path}');
    }
    return await file.writeAsString(content, flush: true);
  }

  /// 创建新目录
  Future<Directory> createDirectory(String parentPath, String dirName) async {
    final dir = Directory(p.join(parentPath, dirName));
    if (await dir.exists()) {
      throw Exception('Directory already exists: ${dir.path}');
    }
    return await dir.create(recursive: false);
  }

  /// 删除文件或目录
  Future<void> deleteEntity(String path) async {
    final file = File(path);
    final dir = Directory(path);

    if (await file.exists()) {
      await file.delete();
    } else if (await dir.exists()) {
      await dir.delete(recursive: true);
    } else {
      throw Exception('Path not found: $path');
    }
  }

  /// 重命名文件或目录，返回新路径
  Future<String> renameEntity(String path, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) throw Exception('名称不能为空');
    if (name.contains('/') || name.contains(r'\')) {
      throw Exception('名称不能包含路径分隔符');
    }

    final parent = p.dirname(path);
    final target = p.join(parent, name);
    if (target == path) return path;
    if (await File(target).exists() || await Directory(target).exists()) {
      throw Exception('同名文件或目录已存在: $name');
    }

    if (await File(path).exists()) {
      await File(path).rename(target);
    } else if (await Directory(path).exists()) {
      await Directory(path).rename(target);
    } else {
      throw Exception('Path not found: $path');
    }
    return target;
  }

  /// 判断文件是否是代码文件
  static bool isCodeFile(String extension) {
    const codeExts = {
      'dart',
      'yaml',
      'yml',
      'json',
      'xml',
      'gradle',
      'kts',
      'properties',
      'html',
      'css',
      'js',
      'kt',
      'java',
      'swift',
      'plist',
      'md',
      'txt',
    };
    return codeExts.contains(extension.toLowerCase());
  }
}
