import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/desktop_prefs_service.dart';
import '../services/local_build/artifact_resolver.dart';
import '../services/local_build/local_build_models.dart';
import '../services/local_build/local_build_service.dart';
import '../services/local_build/local_preview_service.dart';
import '../services/toolchain/toolchain_environment.dart';
import '../services/toolchain/toolchain_manager.dart';
import '../services/toolchain/toolchain_models.dart';

/// 本地构建状态：命令执行、日志、产物、历史。
class LocalBuildProvider extends ChangeNotifier {
  final LocalBuildService _service = LocalBuildService();
  final ArtifactResolver _resolver = const ArtifactResolver();
  final ToolchainManager _toolchains = ToolchainManager.instance;

  LocalBuildTask? _current;
  LocalBuildTask? get current => _current;

  final List<LocalBuildTask> _history = [];

  /// 最近任务（含历史摘要，最多 20 条）
  List<LocalBuildTask> get history => List.unmodifiable(_history);

  String? _lastError;
  String? get lastError => _lastError;

  Uri? _previewUri;
  Uri? get previewUri => _previewUri;

  bool get isRunning => _current?.isRunning == true;

  static const int _maxLogLines = 4000;

  /// 读取历史记录（本地偏好）。
  void loadHistory() {
    if (_history.isNotEmpty) return;
    for (final raw in DesktopPrefsService.instance.recentBuilds) {
      try {
        final data = jsonDecode(raw);
        if (data is! Map) continue;
        final task = LocalBuildTask.fromHistoryJson(data.cast<String, dynamic>());
        if (task != null) _history.add(task);
      } catch (_) {
        // 跳过损坏记录
      }
    }
    if (_history.isNotEmpty) notifyListeners();
  }

  /// 前置条件检查（返回错误文案，可用时返回 null）。
  String? prerequisiteError(LocalBuildTarget target, {String? projectPath}) {
    if (target.requiresFlutter &&
        _toolchains.resolveExecutable(
              ToolchainKind.flutter,
              projectPath: projectPath,
            ) ==
            null) {
      return '未找到 Flutter，请在「工具链」中安装或切换到可用版本';
    }
    if (target.requiresNode &&
        _toolchains.resolveExecutable(
              ToolchainKind.node,
              projectPath: projectPath,
            ) ==
            null) {
      return '未找到 Node.js，请在「工具链」中安装';
    }
    if (target.requiresAndroidSdk &&
        ToolchainEnvironment.detectAndroidSdk() == null) {
      return '未检测到 Android SDK，无法在本地构建 Android 产物';
    }
    if (target.requiresPython &&
        _toolchains.resolveExecutable(
              ToolchainKind.python,
              projectPath: projectPath,
            ) ==
            null) {
      return '未找到 Python，请在「工具链」中安装或切换到可用版本';
    }
    if (target.requiresJava &&
        _toolchains.resolveExecutable(
              ToolchainKind.java,
              projectPath: projectPath,
            ) ==
            null) {
      return '未找到 JDK，请在「工具链」中安装或切换到可用版本';
    }
    if (target.requiresCompiler && !ToolchainEnvironment.hasCppCompiler()) {
      return '未检测到 C++ 编译器（gcc / clang / cl / g++），请先安装';
    }
    return null;
  }

  /// 启动任务；返回是否成功（失败原因见 [lastError]）。
  Future<bool> start({
    required String projectPath,
    required String payloadId,
    required LocalBuildTarget target,
    required LocalTaskKind kind,
  }) async {
    if (isRunning) {
      _lastError = '已有任务正在运行，请先停止';
      notifyListeners();
      return false;
    }
    final precheck = prerequisiteError(target, projectPath: projectPath);
    if (precheck != null) {
      _lastError = precheck;
      notifyListeners();
      return false;
    }

    List<LocalBuildStep> steps;
    try {
      steps = await _service.plan(
        projectPath: projectPath,
        target: target,
        kind: kind,
      );
    } catch (e) {
      _lastError = '$e';
      notifyListeners();
      return false;
    }

    _lastError = null;
    _previewUri = null;
    final task = LocalBuildTask(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      projectPath: projectPath,
      target: target,
      kind: kind,
      steps: steps,
    );
    _current = task;
    notifyListeners();

    // HTML 运行：直接启动本地静态预览服务
    if (target.payloadId == 'html' && kind == LocalTaskKind.run) {
      try {
        _previewUri = await LocalPreviewService.instance.serve(projectPath);
        _appendLog(task, '本地预览已启动：$_previewUri');
        task.status = LocalTaskStatus.success;
        task.finishedAt = DateTime.now();
      } catch (e) {
        _appendLog(task, '启动本地预览失败：$e');
        task.status = LocalTaskStatus.failed;
        task.error = '$e';
        task.finishedAt = DateTime.now();
      }
      notifyListeners();
      _record(task);
      return task.status == LocalTaskStatus.success;
    }

    final environment =
        _toolchains.environment(projectPath: projectPath).build();

    final exitCode = await _service.execute(
      task: task,
      environment: environment,
      onLog: (line) => _appendLog(task, line),
      onUpdate: notifyListeners,
    );

    if (_service.wasCancelled) {
      task.status = LocalTaskStatus.cancelled;
    } else if (exitCode == 0) {
      task.status = LocalTaskStatus.success;
    } else {
      task.status = LocalTaskStatus.failed;
      task.error ??= '命令退出码：$exitCode';
    }
    task.finishedAt = DateTime.now();

    if (task.status == LocalTaskStatus.success) {
      final artifacts = await _resolver.resolve(
        projectPath: projectPath,
        target: target,
      );
      task.artifacts
        ..clear()
        ..addAll(artifacts);
      final customPath = target.id == 'custom.script'
          ? await _resolver.customArtifactPath(projectPath)
          : null;
      if (customPath != null) {
        final file = File(customPath);
        if (await file.exists()) {
          final stat = await file.stat();
          task.artifacts.insert(
            0,
            LocalArtifact(
              path: customPath,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
            ),
          );
        }
      }
      if (task.artifacts.isNotEmpty) {
        final first = task.artifacts.first;
        _appendLog(
          task,
          '产物：${first.path}（${_describeSize(first.sizeBytes)}）',
        );
        // Web / HTML 产物提供一键预览
        if (target.flutterTarget == 'web' ||
            (target.payloadId == 'html' && first.path.endsWith('index.html')) ||
            target.payloadId == 'html') {
          try {
            _previewUri = await LocalPreviewService.instance.serve(
              Directory(first.path).existsSync() ? first.path : projectPath,
            );
            _appendLog(task, '预览地址：$_previewUri');
          } catch (e) {
            debugPrint('启动产物预览失败：$e');
          }
        }
      }
    }

    notifyListeners();
    _record(task);
    return task.status == LocalTaskStatus.success;
  }

  void cancel() {
    _service.cancel();
    final task = _current;
    if (task != null && task.isRunning) {
      _appendLog(task, '正在停止…');
      notifyListeners();
    }
  }

  Future<void> stopPreview() async {
    await LocalPreviewService.instance.stop();
    _previewUri = null;
    notifyListeners();
  }

  Future<void> revealArtifact(LocalArtifact artifact) =>
      _service.reveal(artifact.path);

  Future<void> revealPath(String path) => _service.reveal(path);

  void clearLogs() {
    _current?.logs.clear();
    notifyListeners();
  }

  void _appendLog(LocalBuildTask task, String line) {
    task.logs.add(line);
    if (task.logs.length > _maxLogLines) {
      task.logs.removeRange(0, task.logs.length - _maxLogLines);
    }
  }

  /// 记录到内存历史 + 本地偏好（最多 20 条）。
  void _record(LocalBuildTask task) {
    _history.removeWhere((item) => item.id == task.id);
    _history.insert(0, task);
    if (_history.length > 20) _history.removeRange(20, _history.length);
    DesktopPrefsService.instance.update(() {
      final list = DesktopPrefsService.instance.recentBuilds;
      list.insert(0, jsonEncode(task.toHistoryJson()));
      if (list.length > 20) list.removeRange(20, list.length);
    });
    notifyListeners();
  }

  String _describeSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
