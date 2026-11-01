import 'package:flutter/foundation.dart';

import '../models/file_node.dart';
import '../payloads/project_payload.dart';
import '../services/file_service.dart';
import '../services/project_history_service.dart';

/// 项目状态 Provider
///
/// 管理当前打开的项目路径、文件树与项目载荷（Payload）
class ProjectProvider extends ChangeNotifier {
  final FileService _fileService = FileService();

  String? _projectPath;
  String? get projectPath => _projectPath;

  FileNode? _fileTree;
  FileNode? get fileTree => _fileTree;

  ProjectPayload? _payload;

  /// 当前项目载荷（决定模板 / 高亮 / Actions）
  ProjectPayload get payload => _payload ?? PayloadRegistry.byId(null);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  /// 项目切换回调（main 中注入，用于重置编辑器 / 构建等按项目隔离的状态）
  Future<void> Function(String? projectPath)? onProjectChanged;

  /// 打开已有项目
  Future<void> openProject(String path) async {
    _projectPath = path;
    _payload = await PayloadRegistry.detect(path);
    // 先切换工作区，再加载文件树，避免新项目首帧仍显示上一个项目的标签页
    await onProjectChanged?.call(path);
    await refreshFileTree();
  }

  /// 关闭当前项目
  Future<void> closeProject() async {
    _projectPath = null;
    _fileTree = null;
    _payload = null;
    _error = null;
    await onProjectChanged?.call(null);
    notifyListeners();
  }

  /// 刷新文件树
  Future<void> refreshFileTree() async {
    if (_projectPath == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _fileTree = await _fileService.loadDirectory(_projectPath!);
      // 成功打开后记入历史（不影响主流程）
      if (_error == null) {
        ProjectHistoryService.instance.touch(_projectPath!);
      }
    } catch (e) {
      _error = 'Failed to load directory: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
