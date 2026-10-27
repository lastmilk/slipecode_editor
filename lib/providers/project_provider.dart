import 'package:flutter/foundation.dart';
import '../models/file_node.dart';
import '../services/file_service.dart';
import '../services/project_history_service.dart';

/// 项目状态 Provider
///
/// 管理当前打开的项目路径和文件树
class ProjectProvider extends ChangeNotifier {
  final FileService _fileService = FileService();

  String? _projectPath;
  String? get projectPath => _projectPath;

  FileNode? _fileTree;
  FileNode? get fileTree => _fileTree;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  /// 打开已有项目
  Future<void> openProject(String path) async {
    _projectPath = path;
    await refreshFileTree();
  }

  /// 关闭当前项目
  void closeProject() {
    _projectPath = null;
    _fileTree = null;
    _error = null;
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
