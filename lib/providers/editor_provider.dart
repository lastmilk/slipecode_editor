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

  /// 刷新已打开文件的内容（Agent 直接改盘后调用）
  Future<void> reloadFile(String path) async {
    final file = _openFiles.where((f) => f.path == path).firstOrNull;
    if (file == null) return;
    try {
      final content = await _fileService.readFile(path);
      final fresh = OpenFile(path: path, content: content);
      final index = _openFiles.indexOf(file);
      _openFiles[index] = fresh;
      if (_activeFile?.path == path) _activeFile = fresh;
      notifyListeners();
    } catch (_) {
      // 读取失败（例如文件已被删除）保持原状态
    }
  }

  /// 刷新全部已打开文件（撤回 AI 改动后调用）
  Future<void> reloadAll() async {
    for (final file in List<OpenFile>.from(_openFiles)) {
      await reloadFile(file.path);
    }
    notifyListeners();
  }

  /// 文件被重命名：同步更新已打开的标签
  void renameOpenFile(String oldPath, String newPath) {
    for (var i = 0; i < _openFiles.length; i++) {
      final file = _openFiles[i];
      if (file.path != oldPath) continue;
      final renamed = OpenFile(
        path: newPath,
        content: file.content,
        originalContent: file.originalContent,
      );
      _openFiles[i] = renamed;
      if (_activeFile?.path == oldPath) _activeFile = renamed;
    }
    notifyListeners();
  }

  /// 目录被重命名：同步更新目录下已打开的标签
  void renameDirectory(String oldDir, String newDir) {
    for (var i = 0; i < _openFiles.length; i++) {
      final file = _openFiles[i];
      final oldPrefix = '$oldDir/';
      final winPrefix = '$oldDir\\';
      if (file.path.startsWith(oldPrefix) || file.path.startsWith(winPrefix)) {
        final suffix = file.path.substring(oldDir.length);
        final renamed = OpenFile(
          path: '$newDir$suffix',
          content: file.content,
          originalContent: file.originalContent,
        );
        _openFiles[i] = renamed;
        if (_activeFile?.path == file.path) _activeFile = renamed;
      }
    }
    notifyListeners();
  }

  /// 文件或目录被删除：关闭受影响的标签
  void closeFilesUnder(String path) {
    final deleted = _openFiles
        .where((f) => f.path == path || f.path.startsWith('$path/') || f.path.startsWith('$path\\'))
        .map((f) => f.path)
        .toList();
    for (final filePath in deleted) {
      closeFile(filePath);
    }
  }

  /// 保存活动文件
  Future<bool> saveActiveFile() async {
    if (_activeFile == null) return false;
    return saveFile(_activeFile!.path);
  }

  /// 保存指定文件（原位替换，保持标签顺序）
  Future<bool> saveFile(String path) async {
    final index = _openFiles.indexWhere((f) => f.path == path);
    if (index == -1) return false;
    final file = _openFiles[index];
    return _writeAndRefresh(index, file.content);
  }

  /// 把指定内容写入文件并刷新保存基线
  ///
  /// 用于「路径 + 内容」快照的写入（如 VibeCoding），
  /// 避免用户切换标签后把内容写到别的文件里。
  Future<bool> saveContent(String path, String content) async {
    final index = _openFiles.indexWhere((f) => f.path == path);
    if (index == -1) return false;
    return _writeAndRefresh(index, content);
  }

  Future<bool> _writeAndRefresh(int index, String content) async {
    final path = _openFiles[index].path;
    try {
      await _fileService.writeFile(path, content);
      final freshFile = OpenFile(path: path, content: content);
      _openFiles[index] = freshFile;
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

  /// 替换文件中一段文本并立即保存（VibeCoding 删除触发词用）
  Future<bool> replaceRangeAndSave(
    String path,
    int start,
    int end,
    String replacement,
  ) async {
    final index = _openFiles.indexWhere((f) => f.path == path);
    if (index == -1) return false;
    final file = _openFiles[index];
    if (start < 0 ||
        end > file.content.length ||
        start > end) {
      return false;
    }
    file.updateContent(file.content.replaceRange(start, end, replacement));
    return _writeAndRefresh(index, file.content);
  }

  /// 指定文件是否有未保存修改
  bool isModified(String path) {
    for (final file in _openFiles) {
      if (file.path == path) return file.isModified;
    }
    return false;
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
