/// 已打开文件模型
class OpenFile {
  final String path;
  String content;
  final String originalContent;

  OpenFile({
    required this.path,
    required this.content,
  }) : originalContent = content;

  bool get isModified => content != originalContent;

  /// 文件名（不含路径）
  String get name {
    final separator = path.contains('\\') ? '\\' : '/';
    return path.split(separator).last;
  }

  /// 文件扩展名（小写，不含点）
  String get extension => name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';

  void updateContent(String newContent) {
    content = newContent;
  }
}
