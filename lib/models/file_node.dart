import 'dart:io';

/// 文件树节点类型
enum FileNodeType { file, directory }

/// 文件树节点模型
class FileNode {
  final String name;
  final String path;
  final FileNodeType type;
  final List<FileNode> children;

  const FileNode({
    required this.name,
    required this.path,
    required this.type,
    this.children = const [],
  });

  bool get isDirectory => type == FileNodeType.directory;
  bool get isFile => type == FileNodeType.file;

  String get extension => name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';

  static FileNode fromEntity(FileSystemEntity entity, {List<FileNode>? children}) {
    return FileNode(
      name: entity.path.split(Platform.pathSeparator).last,
      path: entity.path,
      type: entity is Directory ? FileNodeType.directory : FileNodeType.file,
      children: children ?? const [],
    );
  }
}
