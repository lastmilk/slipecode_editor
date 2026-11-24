import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/desktop_prefs_service.dart';
import '../services/toolchain/toolchain_environment.dart';
import '../services/toolchain/toolchain_manager.dart';
import '../services/toolchain/toolchain_models.dart';

/// 工具链管理状态。
class ToolchainProvider extends ChangeNotifier {
  final ToolchainManager _manager = ToolchainManager.instance;

  bool _initialized = false;
  bool get initialized => _initialized;

  final Map<ToolchainKind, List<ToolchainRelease>> _releases = {};
  final Map<ToolchainKind, bool> _loadingReleases = {};
  final Map<ToolchainKind, String> _releaseErrors = {};

  ToolchainProgress? _progress;
  ToolchainProgress? get progress => _progress;

  ToolchainCancelToken? _cancelToken;

  bool _installing = false;
  bool get installing => _installing;

  int _diskUsage = 0;
  int get diskUsage => _diskUsage;

  final List<ToolchainKind> _verifying = [];
  final Map<String, String> _verifyResults = {};

  Future<void> _queue = Future.value();

  bool get useMirror =>
      DesktopPrefsService.instance.toolchainMirror == 'cn';

  String? get androidSdk => ToolchainEnvironment.detectAndroidSdk();

  Future<void> initialize() async {
    if (_initialized) return;
    await _manager.initialize();
    _initialized = true;
    notifyListeners();
    unawaited(refreshDiskUsage());
  }

  List<InstalledToolchain> installedOf(ToolchainKind kind) =>
      _manager.installedOf(kind);

  List<ToolchainRelease> releasesOf(ToolchainKind kind) =>
      _releases[kind] ?? const [];

  bool isLoadingReleases(ToolchainKind kind) =>
      _loadingReleases[kind] == true;

  String? releaseError(ToolchainKind kind) => _releaseErrors[kind];

  String? defaultVersion(ToolchainKind kind) =>
      _manager.defaultVersion(kind);

  String? pinnedVersion(ToolchainKind kind, String? projectPath) =>
      _manager.pinnedVersion(kind, projectPath);

  String? activeVersion(ToolchainKind kind, {String? projectPath}) =>
      _manager.activeVersion(kind, projectPath: projectPath);

  String? resolveExecutable(ToolchainKind kind, {String? projectPath}) =>
      _manager.resolveExecutable(kind, projectPath: projectPath);

  ToolchainEnvironment environment({String? projectPath}) =>
      _manager.environment(projectPath: projectPath);

  bool isVerifying(InstalledToolchain toolchain) =>
      _verifying.contains(toolchain.kind) == true;

  String? verifyResult(InstalledToolchain toolchain) =>
      _verifyResults[_key(toolchain)];

  String _key(InstalledToolchain toolchain) =>
      '${toolchain.kind.id}@${toolchain.version}';

  void toggleMirror(bool enabled) {
    DesktopPrefsService.instance
        .update(() => DesktopPrefsService.instance.toolchainMirror =
            enabled ? 'cn' : 'official');
    // 镜像变化后已加载的清单需要重新拉取
    final loaded = _releases.keys.toList();
    _releases.clear();
    _releaseErrors.clear();
    notifyListeners();
    for (final kind in loaded) {
      unawaited(refreshReleases(kind, forceRefresh: true));
    }
  }

  Future<void> refreshReleases(
    ToolchainKind kind, {
    bool forceRefresh = false,
  }) async {
    if (_loadingReleases[kind] == true) return;
    _loadingReleases[kind] = true;
    _releaseErrors.remove(kind);
    notifyListeners();
    try {
      final list = await _manager.catalog.releases(
        kind,
        useMirror: useMirror,
        forceRefresh: forceRefresh,
      );
      _releases[kind] = list;
      if (list.isEmpty) {
        _releaseErrors[kind] = 'noVersions';
      }
    } catch (e) {
      _releaseErrors[kind] = '$e';
    } finally {
      _loadingReleases[kind] = false;
      notifyListeners();
    }
  }

  /// 安装任务排队执行（同一时间只有一个下载 / 安装任务）。
  Future<bool> install(ToolchainRelease release) async {
    final completer = Completer<bool>();
    _queue = _queue.then((_) async {
      final result = await _runInstall(release);
      if (!completer.isCompleted) completer.complete(result);
    }).catchError((Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    return completer.future;
  }

  Future<bool> _runInstall(ToolchainRelease release) async {
    final token = ToolchainCancelToken();
    _cancelToken = token;
    _installing = true;
    _progress = ToolchainProgress(
      kind: release.kind,
      version: release.version,
      phase: ToolchainPhase.queued,
    );
    notifyListeners();
    try {
      final record = await _manager.install(
        release,
        cancelToken: token,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
      );
      // 首个安装的工具链自动设为默认
      if (_manager.defaultVersion(release.kind) == null) {
        _manager.setDefault(release.kind, record.version);
      }
      unawaited(refreshDiskUsage());
      return true;
    } on ToolchainCancelledException {
      _progress = _progress?.copyWith(phase: ToolchainPhase.cancelled);
      return false;
    } catch (e) {
      debugPrint('安装 ${release.kind.id}@${release.version} 失败：$e');
      _progress = ToolchainProgress(
        kind: release.kind,
        version: release.version,
        phase: ToolchainPhase.failed,
        message: '$e',
      );
      return false;
    } finally {
      _installing = false;
      _cancelToken = null;
      notifyListeners();
    }
  }

  void cancelInstall() {
    _cancelToken?.cancel();
    _progress = _progress?.copyWith(phase: ToolchainPhase.cancelled);
    notifyListeners();
  }

  Future<void> uninstall(InstalledToolchain toolchain) async {
    await _manager.uninstall(toolchain);
    _verifyResults.remove(_key(toolchain));
    notifyListeners();
    unawaited(refreshDiskUsage());
  }

  void setDefault(ToolchainKind kind, String? version) {
    _manager.setDefault(kind, version);
    notifyListeners();
  }

  void pinProject(ToolchainKind kind, String? projectPath, String? version) {
    if (projectPath == null || projectPath.isEmpty) return;
    _manager.pinProject(kind, projectPath, version);
    notifyListeners();
  }

  Future<void> verify(InstalledToolchain toolchain) async {
    if (_verifying.contains(toolchain.kind)) return;
    _verifying.add(toolchain.kind);
    _verifyResults.remove(_key(toolchain));
    notifyListeners();
    try {
      final output = await _manager.verify(toolchain);
      _verifyResults[_key(toolchain)] = output.isEmpty ? 'ok' : output;
    } catch (e) {
      _verifyResults[_key(toolchain)] = '$e';
    } finally {
      _verifying.remove(toolchain.kind);
      notifyListeners();
    }
  }

  Future<void> refreshDiskUsage() async {
    _diskUsage = await _manager.diskUsage();
    notifyListeners();
  }
}
