import 'package:flutter/foundation.dart';

import '../services/build_service.dart';
import '../services/github_api_service.dart';
import 'git_sync_provider.dart';
import 'github_provider.dart';

/// 构建状态
enum BuildStatus { idle, running, success, failed, cancelled }

/// 构建状态管理（GitHub Actions 云端构建）
///
/// 流程：同步本地代码 → 确保 workflow 存在 → 触发 dispatch →
/// 轮询运行状态 → 下载产物。
class BuildProvider extends ChangeNotifier {
  BuildProvider(this._github, this._gitSync);

  final GitHubProvider _github;
  final GitSyncProvider _gitSync;

  BuildStatus _status = BuildStatus.idle;
  BuildType _type = BuildType.apkRelease;

  final List<String> _logs = [];
  String? _artifactPath;
  String _error = '';
  String _currentTask = '';
  String _runUrl = '';

  DateTime? _startedAt;
  DateTime? _finishedAt;
  bool _cancelRequested = false;
  bool _disposed = false;

  BuildStatus get status => _status;
  BuildType get type => _type;
  List<String> get logs => List.unmodifiable(_logs);
  String? get artifactPath => _artifactPath;
  String get error => _error;
  String get currentTask => _currentTask;
  String get runUrl => _runUrl;
  DateTime? get startedAt => _startedAt;
  DateTime? get finishedAt => _finishedAt;

  bool get isRunning => _status == BuildStatus.running;

  Duration? get duration {
    if (_startedAt == null) return null;
    return (_finishedAt ?? DateTime.now()).difference(_startedAt!);
  }

  void setType(BuildType type) {
    if (isRunning) return;
    _type = type;
    notifyListeners();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _append(String line) {
    if (line.isEmpty) return;
    _logs.add(line);
    if (_logs.length > 4000) {
      _logs.removeRange(0, _logs.length - 4000);
    }
    _safeNotify();
  }

  void _reset() {
    _logs.clear();
    _artifactPath = null;
    _error = '';
    _runUrl = '';
    _startedAt = DateTime.now();
    _finishedAt = null;
    _cancelRequested = false;
    _safeNotify();
  }

  /// 开始云端构建
  Future<void> startBuild({required String projectDir}) async {
    if (isRunning) return;

    final api = _github.api;
    final repo = _github.repoFor(projectDir);
    if (api == null || repo == null) {
      _status = BuildStatus.failed;
      _error = '尚未连接 GitHub 或项目未关联仓库';
      _append('==> 失败：$_error');
      _safeNotify();
      return;
    }

    _status = BuildStatus.running;
    _currentTask = '云端构建 ${_type.label}';
    _reset();
    _append('==> 开始构建 ${_type.label}（GitHub Actions）');

    try {
      // 1. 先把本地未同步的改动推上去
      _currentTask = '同步本地改动';
      _append('==> 同步本地改动到 $repo');
      if (_gitSync.pendingCount > 0) {
        _append('    待同步文件：${_gitSync.pendingCount} 个');
        final ok = await _gitSync.syncNow();
        if (!ok) throw StateError('同步失败：${_gitSync.error ?? '未知错误'}');
      } else {
        _append('    无待同步改动');
      }

      // 2. 确保 workflow 存在
      _currentTask = '检查构建 workflow';
      _append('==> 检查 GitHub Actions workflow');
      await BuildService.instance.ensureWorkflow(api, repo);
      _append('    workflow 已就绪');

      // 3. 触发构建
      _currentTask = '触发云端构建';
      _append('==> 触发 workflow_dispatch（build_type=${_type.inputValue}）');
      final triggeredAt = await BuildService.instance.dispatch(api, repo, _type);
      _append('    已触发，等待运行开始...');

      // 4. 轮询运行状态
      _currentTask = '云端构建中';
      final run = await BuildService.instance.waitForCompletion(
        api,
        repo,
        triggeredAt,
        isCancelled: () => _cancelRequested,
        onUpdate: (run) {
          _runUrl = run.htmlUrl;
          _append('==> 运行 #${run.runNumber} 状态：${run.status}');
          _safeNotify();
        },
      );
      _runUrl = run.htmlUrl;
      _append('==> 运行结束：${run.conclusion}');
      _append('    $runUrl');

      if (run.conclusion != 'success') {
        _fail('云端构建未成功（${run.conclusion}），请到 GitHub 查看日志');
        return;
      }

      // 5. 下载产物
      _currentTask = '下载构建产物';
      _append('==> 下载构建产物');
      final artifacts = await api.listArtifacts(repo, run.id);
      final usable = artifactsForType(artifacts: artifacts, type: _type);
      if (usable == null) {
        _fail('构建成功但未找到可用产物');
        return;
      }
      final path = await BuildService.instance.downloadAndExtractArtifact(
        api,
        repo,
        usable,
        projectDir,
        _type,
      );
      if (path == null) {
        _fail('产物包内未找到 ${_type.artifactExt} 文件');
        return;
      }
      _artifactPath = path;
      _append('==> 构建产物：$path');
      _status = BuildStatus.success;
      _append('==> 构建成功（耗时 ${_durationText()}）');
    } catch (e) {
      if ('$e' == '已取消') {
        _status = BuildStatus.cancelled;
        _append('==> 已取消（云端运行仍会继续，可在 GitHub 上取消）');
      } else {
        _fail('$e');
      }
    } finally {
      _finishedAt = DateTime.now();
      _currentTask = '';
      _safeNotify();
    }
  }

  /// 从产物列表中挑选与构建类型匹配的产物
  static RunArtifact? artifactsForType({
    required List<RunArtifact> artifacts,
    required BuildType type,
  }) {
    final usable = artifacts.where((a) => !a.expired).toList();
    if (usable.isEmpty) return null;
    final expected = 'slipecode-${type.inputValue}';
    return usable.firstWhere(
      (a) => a.name == expected,
      orElse: () => usable.first,
    );
  }

  void _fail(String message) {
    _error = message;
    _status = BuildStatus.failed;
    _finishedAt = DateTime.now();
    _append('==> 失败：$message');
    _safeNotify();
  }

  String _durationText() {
    final d = duration;
    if (d == null) return '-';
    if (d.inMinutes > 0) {
      return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
    }
    return '${d.inSeconds} 秒';
  }

  /// 取消当前任务（停止本地轮询；云端运行不会被取消）
  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _append('==> 正在取消...');
    _safeNotify();
  }

  /// 安装构建产物 APK
  Future<bool> installArtifact() async {
    if (_artifactPath == null) return false;
    if (!_artifactPath!.endsWith('.apk')) {
      _error = 'AppBundle 产物无法直接安装，请先构建 APK';
      _safeNotify();
      return false;
    }
    return BuildService.instance.installApk(_artifactPath!);
  }

  void clearLogs() {
    _logs.clear();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
