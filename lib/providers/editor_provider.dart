import 'package:flutter/foundation.dart';
import '../models/open_file.dart';
import '../services/file_service.dart';

/// 编辑器状态 Provider
///
/// 管理多标签页打开、切换、保存等操作
class EditorProvider extends ChangeNotifier {
  final FileService _fileService = FileService();

  final List<OpenFile> _openFiles = [];
  List<OpenFile> get openFiles => List.unmodifiable(_openFiles);

  OpenFile? _activeFile;
  OpenFile? get activeFile => _activeFile;

  bool get hasActiveFile => _activeFile != null;

  /// 打开文件（如果已打开则切换到它）
  Future<OpenFile?> openFile(String path) async {
    // 已打开？直接切换
    final existing = _openFiles.where((f) => f.path == path).firstOrNull;
    if (existing != null) {
      _activeFile = existing;
      notifyListeners();
      return existing;
    }

    try {
      final content = await _fileService.readFile(path);
      final openFile = OpenFile(path: path, content: content);
      _openFiles.add(openFile);
      _activeFile = openFile;
      notifyListeners();
      return openFile;
    } catch (e) {
      debugPrint('Error opening file $path: $e');
      return null;
    }
  }

  /// 关闭文件
  void closeFile(String path) {
    final index = _openFiles.indexWhere((f) => f.path == path);
    if (index == -1) return;

    final wasActive = _activeFile?.path == path;
    _openFiles.removeAt(index);

    if (wasActive) {
      // 切换到相邻标签
      if (_openFiles.isNotEmpty) {
        final newIndex = index > 0 ? index - 1 : 0;
        _activeFile = _openFiles[newIndex.clamp(0, _openFiles.length - 1)];
      } else {
        _activeFile = null;
      }
    }
    notifyListeners();
  }

  /// 切换活动文件
  void setActiveFile(String path) {
    final file = _openFiles.where((f) => f.path == path).firstOrNull;
    if (file != null) {
      _activeFile = file;
      notifyListeners();
    }
  }

  /// 更新活动文件的内容
  void updateActiveContent(String content) {
    if (_activeFile != null) {
      _activeFile!.updateContent(content);
      notifyListeners();
    }
  }

  /// 保存活动文件
  Future<bool> saveActiveFile() async {
    if (_activeFile == null) return false;
    return saveFile(_activeFile!.path);
  }

  /// 保存指定文件
  Future<bool> saveFile(String path) async {
    final file = _openFiles.where((f) => f.path == path).firstOrNull;
    if (file == null) return false;

    try {
      await _fileService.writeFile(path, file.content);
      // 重新从文件创建以更新 originalContent
      _openFiles.removeWhere((f) => f.path == path);
      final freshFile = OpenFile(path: path, content: file.content);
      _openFiles.add(freshFile);
      if (_activeFile?.path == path) {
        _activeFile = freshFile;
      }
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error saving file $path: $e');
      return false;
    }
  }

  /// 保存所有已修改的文件
  Future<int> saveAll() async {
    int saved = 0;
    final modified = List<OpenFile>.from(_openFiles.where((f) => f.isModified));
    for (final file in modified) {
      if (await saveFile(file.path)) saved++;
    }
    return saved;
  }

  /// 是否有未保存的修改
  bool get hasUnsavedChanges => _openFiles.any((f) => f.isModified);
}
