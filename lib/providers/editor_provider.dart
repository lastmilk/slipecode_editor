import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/editor_diagnostic.dart';
import '../models/open_file.dart';
import '../services/file_service.dart';
import '../services/lua/editor_service_adapter.dart';

/// 编辑器状态 Provider
///
/// 管理多标签页打开、切换、保存等操作。
/// 每个项目拥有独立的标签页工作区：切换项目时先保存当前项目的
/// 打开列表，再恢复目标项目上次打开的文件。
class EditorProvider extends ChangeNotifier {
  EditorProvider({EditorServiceAdapter? plugins})
    : _plugins = plugins ?? EditorServiceAdapter();

  final FileService _fileService = FileService();
  final EditorServiceAdapter _plugins;

  final List<OpenFile> _openFiles = [];

  /// 当前绑定的项目路径（用于按项目持久化标签页）
  String? _boundProjectPath;
  String? get boundProjectPath => _boundProjectPath;

  List<OpenFile> get openFiles => List.unmodifiable(_openFiles);

  OpenFile? _activeFile;
  OpenFile? get activeFile => _activeFile;

  bool get hasActiveFile => _activeFile != null;

  // ---------------------------------------------------------------------------
  // 按项目隔离的工作区
  // ---------------------------------------------------------------------------

  static const _tabsPrefix = 'editor_tabs_';

  String _tabsKey(String projectPath) =>
      '$_tabsPrefix${base64Url.encode(utf8.encode(projectPath))}';

  /// 切换项目：保存旧项目的标签页，再恢复新项目的标签页
  ///
  /// [projectPath] 为 null 表示关闭项目（清空工作区）。
  Future<void> switchProject(String? projectPath) async {
    if (_boundProjectPath == projectPath) return;
    await _persistTabs();
    _boundProjectPath = projectPath;
    _openFiles.clear();
    _activeFile = null;
    if (projectPath != null) {
      await _restoreTabs(projectPath);
    }
    notifyListeners();
  }

  /// 保存当前项目的打开文件列表（只记录路径，内容打开时重新读取）
  Future<void> _persistTabs() async {
    final projectPath = _boundProjectPath;
    if (projectPath == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _tabsKey(projectPath);
      if (_openFiles.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode({
          'files': _openFiles.map((f) => f.path).toList(),
          'active': _activeFile?.path,
        }),
      );
    } catch (e) {
      debugPrint('保存编辑器工作区失败：$e');
    }
  }

  /// 恢复项目上次打开的标签页
  Future<void> _restoreTabs(String projectPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tabsKey(projectPath));
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final paths = (data['files'] as List? ?? [])
          .whereType<String>()
          .where((path) => File(path).existsSync())
          .toList();
      final activePath = data['active'] as String?;
      for (final path in paths) {
        try {
          final content = await _fileService.readFile(path);
          _openFiles.add(OpenFile(path: path, content: content));
        } catch (e) {
          debugPrint('跳过无法读取的文件 $path：$e');
        }
      }
      if (_openFiles.isNotEmpty) {
        _activeFile = _openFiles.firstWhere(
          (f) => f.path == activePath,
          orElse: () => _openFiles.first,
        );
      }
    } catch (e) {
      debugPrint('恢复编辑器工作区失败：$e');
    }
  }

  /// 打开文件（如果已打开则切换到它），允许 Lua 修改或取消本次操作。
  Future<OpenFile?> openFile(String path) async {
    final will = await _plugins.events.dispatch(
      'file.willOpen',
      _plugins.event('file.willOpen', 'will', {'path': path}),
    );
    if (will.swallowed) return null;
    path = _eventPath(will.event, fallback: path);

    final raw = await _plugins.registry.invoke(
      'editor',
      'openFile',
      {'path': path},
      (request) async {
        final requestPath = _requestPath(request);
        final opened = await _openFileDefault(requestPath);
        return {'path': requestPath, 'opened': opened != null};
      },
    );
    final result = _resultMap(raw, 'editor.openFile');
    if (result['opened'] is! bool) {
      throw const FormatException('editor.openFile 返回值缺少 bool opened');
    }
    final resultPath = result['path'] is String
        ? result['path'] as String
        : path;
    if (result['opened'] == false) return null;
    final opened = _openFiles
        .where((file) => file.path == resultPath)
        .firstOrNull;
    if (opened != null) {
      await _plugins.events.dispatch(
        'file.didOpen',
        _plugins.event('file.didOpen', 'did', {'path': opened.path}),
      );
    }
    return opened;
  }

  Future<OpenFile?> _openFileDefault(String path) async {
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
      unawaited(_persistTabs());
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
    unawaited(_persistTabs());
  }

  /// 切换活动文件
  void setActiveFile(String path) {
    final file = _openFiles.where((f) => f.path == path).firstOrNull;
    if (file != null) {
      _activeFile = file;
      notifyListeners();
      unawaited(_persistTabs());
    }
  }

  /// 更新活动文件的内容
  ///
  /// 内容本身立即写入（保存 / 未保存判断不受影响），但通知做节流：
  /// 连续输入时每 120ms 最多触发一次重建，避免每敲一个字符就重建整屏。
  void updateActiveContent(String content) {
    final file = _activeFile;
    if (file == null) return;
    file.updateContent(content);
    final now = DateTime.now();
    if (now.difference(_lastContentNotify).inMilliseconds >= 120) {
      _lastContentNotify = now;
      _contentNotifyTimer?.cancel();
      _contentNotifyTimer = null;
      notifyListeners();
    } else {
      _contentNotifyTimer ??= Timer(const Duration(milliseconds: 120), () {
        _contentNotifyTimer = null;
        _lastContentNotify = DateTime.now();
        notifyListeners();
      });
    }
  }

  DateTime _lastContentNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _contentNotifyTimer;

  @override
  void dispose() {
    _contentNotifyTimer?.cancel();
    super.dispose();
  }

  /// 替换指定文件的内容（LSP 重命名 / Code Action 等外部编辑）
  ///
  /// 只改内存中的标签内容，保持「未保存」状态，由用户决定是否落盘。
  void replaceContent(String path, String content) {
    final file = _openFiles.where((f) => f.path == path).firstOrNull;
    if (file == null || file.content == content) return;
    file.updateContent(content);
    notifyListeners();
  }

  /// 外部编辑服务入口：Lua 可包裹请求，默认仅修改内存并保持未保存状态。
  Future<bool> applyEdit(String path, String content) async {
    final raw = await _plugins.registry.invoke(
      'editor',
      'applyEdit',
      {'path': path, 'content': content},
      (request) {
        final requestPath = _requestPath(request);
        final requestContent = request['content'];
        if (requestContent is! String) {
          throw const FormatException('editor.applyEdit.content 必须为 string');
        }
        final exists = _openFiles.any((file) => file.path == requestPath);
        if (exists) replaceContent(requestPath, requestContent);
        return Future.value({'path': requestPath, 'applied': exists});
      },
    );
    final result = _resultMap(raw, 'editor.applyEdit');
    if (result['applied'] is! bool) {
      throw const FormatException('editor.applyEdit 返回值缺少 bool applied');
    }
    return result['applied'] == true;
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
    unawaited(_persistTabs());
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
    unawaited(_persistTabs());
  }

  /// 文件或目录被删除：关闭受影响的标签
  void closeFilesUnder(String path) {
    final deleted = _openFiles
        .where(
          (f) =>
              f.path == path ||
              f.path.startsWith('$path/') ||
              f.path.startsWith('$path\\'),
        )
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
    final file = _openFiles.where((item) => item.path == path).firstOrNull;
    if (file == null) return false;
    return _saveWithPlugins(path, file.content);
  }

  /// 把指定内容写入文件并刷新保存基线；Lua 可以修改内容或取消保存。
  Future<bool> saveContent(String path, String content) async {
    return _saveWithPlugins(path, content);
  }

  Future<bool> _saveWithPlugins(String path, String content) async {
    final will = await _plugins.events.dispatch(
      'file.willSave',
      _plugins.event('file.willSave', 'will', {
        'path': path,
        'content': content,
      }),
    );
    if (will.swallowed) return false;
    final payload = will.event['payload'];
    if (payload is! Map) {
      throw const FormatException('file.willSave 缺少 payload 对象');
    }
    path = payload['path'] is String ? payload['path'] as String : path;
    content = payload['content'] is String
        ? payload['content'] as String
        : content;

    final raw = await _plugins.registry.invoke(
      'editor',
      'saveFile',
      {'path': path, 'content': content},
      (request) async {
        final requestPath = _requestPath(request);
        final requestContent = request['content'];
        if (requestContent is! String) {
          throw const FormatException('editor.saveFile.content 必须为 string');
        }
        final index = _openFiles.indexWhere((file) => file.path == requestPath);
        if (index < 0) return {'path': requestPath, 'saved': false};
        final saved = await _writeAndRefresh(index, requestContent);
        return {'path': requestPath, 'saved': saved};
      },
    );
    final result = _resultMap(raw, 'editor.saveFile');
    if (result['saved'] is! bool) {
      throw const FormatException('editor.saveFile 返回值缺少 bool saved');
    }
    final saved = result['saved'] == true;
    if (saved) {
      await _plugins.events.dispatch(
        'file.didSave',
        _plugins.event('file.didSave', 'did', {
          'path': path,
          'content': content,
        }),
      );
    }
    return saved;
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
    if (start < 0 || end > file.content.length || start > end) {
      return false;
    }
    file.updateContent(file.content.replaceRange(start, end, replacement));
    return saveContent(path, file.content);
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

  // ---------------------------------------------------------------------------
  // 诊断（LSP / 本地分析）
  // ---------------------------------------------------------------------------

  final Map<String, List<EditorDiagnostic>> _diagnostics = {};

  /// 指定文件的诊断
  List<EditorDiagnostic> diagnosticsFor(String path) =>
      _diagnostics[path] ?? const [];

  /// 全部诊断（「问题」面板）
  Map<String, List<EditorDiagnostic>> get allDiagnostics =>
      Map.unmodifiable(_diagnostics);

  int get errorCount => _diagnostics.values
      .expand((list) => list)
      .where((diagnostic) => diagnostic.isError)
      .length;

  int get warningCount => _diagnostics.values
      .expand((list) => list)
      .where((diagnostic) => diagnostic.isWarning)
      .length;

  /// 更新指定文件的诊断
  void setDiagnostics(String path, List<EditorDiagnostic> diagnostics) {
    if (diagnostics.isEmpty) {
      if (_diagnostics.remove(path) != null) notifyListeners();
      return;
    }
    _diagnostics[path] = List.unmodifiable(diagnostics);
    notifyListeners();
  }

  /// 清空诊断（关闭文件 / 断开 LSP）
  void clearDiagnostics([String? path]) {
    if (path == null) {
      if (_diagnostics.isEmpty) return;
      _diagnostics.clear();
    } else if (_diagnostics.remove(path) == null) {
      return;
    }
    notifyListeners();
  }
}

String _eventPath(Map<String, Object?> event, {required String fallback}) {
  final payload = event['payload'];
  if (payload is! Map) throw const FormatException('文件事件缺少 payload 对象');
  final path = payload['path'] ?? fallback;
  if (path is! String || path.isEmpty) {
    throw const FormatException('文件事件 path 必须为非空 string');
  }
  return path;
}

String _requestPath(Map<String, Object?> request) {
  final path = request['path'];
  if (path is! String || path.isEmpty) {
    throw const FormatException('编辑器服务 path 必须为非空 string');
  }
  return path;
}

Map<String, Object?> _resultMap(Object? value, String operation) {
  if (value is! Map) throw FormatException('$operation 返回值必须为对象');
  return value.map((key, value) => MapEntry(key.toString(), value));
}
