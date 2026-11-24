import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/editor_diagnostic.dart';
import '../desktop_platform.dart';
import '../plugin_service.dart';
import '../toolchain/toolchain_manager.dart';
import 'dart_server_discovery.dart';
import 'lsp_client.dart';
import 'lsp_server_store.dart';
import 'lsp_session.dart';

/// 语言服务管理器状态
enum LspManagerState { disabled, stopped, starting, running, failed }

/// 语言服务生命周期管理
///
/// 按工作区根目录启动会话；Dart 走自动发现，自定义服务从配置读取。
/// 崩溃后自动重启一次，状态通过 [ChangeNotifier] 暴露给 Provider。
class LspManager extends ChangeNotifier {
  LspManager._();

  static final LspManager instance = LspManager._();

  final Map<String, LspSession> _sessions = {};

  LspManagerState state = LspManagerState.stopped;
  String? error;
  String? dartVersion;
  String? progress;
  String? _rootPath;

  bool _starting = false;
  bool _restarting = false;
  bool _disposed = false;
  int _restartAttempts = 0;

  /// 诊断回调（路径 → 编辑器诊断）
  void Function(String path, List<EditorDiagnostic> diagnostics)? onDiagnostics;

  /// 服务端提示消息
  void Function(String message)? onMessage;

  bool get isReady => state == LspManagerState.running;

  String? get rootPath => _rootPath;

  List<LspSession> get sessions => List.unmodifiable(_sessions.values);

  /// 文件对应的会话（无则 null）
  LspSession? sessionForPath(String path) {
    for (final session in _sessions.values) {
      if (session.config.handles(path) && session.isRunning) return session;
    }
    return null;
  }

  LspSession? sessionById(String id) => _sessions[id];

  /// 启动（或切换到）工作区
  Future<void> startProject(String rootPath, {bool force = false}) async {
    debugPrint('LSP: startProject($rootPath) state=$state force=$force');
    if (!DesktopPlatform.isDesktop) {
      _setState(LspManagerState.disabled);
      return;
    }
    if (_starting) return;
    if (!force &&
        _rootPath == rootPath &&
        (state == LspManagerState.running ||
            state == LspManagerState.starting)) {
      return;
    }
    _starting = true;
    _rootPath = rootPath;
    progress = null;
    error = null;
    _setState(LspManagerState.starting);
    await _stopSessions();
    _restartAttempts = 0;

    try {
      await LspServerStore.instance.ensureLoaded();
      if (!LspServerStore.instance.dartConfig.enabled) {
        _setState(LspManagerState.disabled);
        return;
      }
      await ToolchainManager.instance.initialize();
      final discovery = await DartServerDiscovery.discover(
        projectPath: rootPath,
      );
      if (discovery.spec == null) {
        error = discovery.error ?? '未找到 Dart 语言服务';
        debugPrint('LSP: 发现失败：$error');
        _setState(LspManagerState.failed);
        return;
      }
      debugPrint(
        'LSP: 使用 ${discovery.spec!.executable} (${discovery.spec!.version})',
      );
      final spec = discovery.spec!;
      dartVersion = spec.version;
      final client = LspClient(spec);
      final session = LspSession(
        client: client,
        rootPath: rootPath,
        config: LspServerStore.instance.dartConfig,
      );
      _wireSession(session);
      await session.start();
      _sessions[spec.id] = session;
      _setState(LspManagerState.running);
      unawaited(_startCustomServers(rootPath));
    } catch (e) {
      error = '$e';
      _setState(LspManagerState.failed);
    } finally {
      _starting = false;
    }
  }

  /// 重启当前工作区
  Future<void> restart() async {
    final root = _rootPath;
    if (root == null) return;
    _restarting = true;
    try {
      await startProject(root, force: true);
    } finally {
      _restarting = false;
    }
  }

  Future<void> stop() async {
    _rootPath = null;
    await _stopSessions();
    if (state != LspManagerState.disabled) _setState(LspManagerState.stopped);
  }

  void _wireSession(LspSession session) {
    session.onDiagnostics = (path, diagnostics) {
      onDiagnostics?.call(path, diagnostics);
    };
    session.onServerMessage = (message) => onMessage?.call(message);
    session.onProgress = (message) {
      progress = message.isEmpty ? null : message;
      _notify();
    };
    final client = session.client;
    client.onExit = (code) {
      if (_restarting || _disposed) return;
      if (_rootPath == null) return;
      if (_restartAttempts >= 1) {
        error = '语言服务异常退出（code=$code）';
        _setState(LspManagerState.failed);
        return;
      }
      _restartAttempts++;
      final root = _rootPath!;
      Future<void>.delayed(const Duration(seconds: 1), () async {
        if (_disposed || _rootPath != root) return;
        await startProject(root, force: true);
      });
    };
  }

  /// 自定义语言服务：尽力启动，失败不影响 Dart 会话
  ///
  /// 除用户手动配置的服务外，还会启动已启用插件贡献的 LSP
  /// （插件与 Payload 无关，这里只消费 plug-in 的 contributes.lsp）。
  Future<void> _startCustomServers(String rootPath) async {
    await PluginService.instance.ensureLoaded();
    final configs = [
      ...LspServerStore.instance.customServers,
      ...PluginService.instance.lspConfigs(),
    ];
    for (final config in configs) {
      if (!config.enabled || !config.autoStart) continue;
      if (config.command.trim().isEmpty) continue;
      try {
        final spec = LspLaunchSpec(
          id: config.id,
          name: config.name,
          executable: config.command,
          args: config.args,
          workingDirectory: rootPath,
          environment: {
            ...config.env,
            ...ToolchainManager.instance
                .environment(projectPath: rootPath)
                .build(),
          },
          initializationOptions: config.initializationOptions,
        );
        final client = LspClient(spec);
        final session = LspSession(
          client: client,
          rootPath: rootPath,
          config: config,
        );
        _wireSession(session);
        await session.start();
        _sessions[config.id] = session;
        _notify();
      } catch (e) {
        debugPrint('启动自定义语言服务 ${config.id} 失败：$e');
      }
    }
  }

  Future<void> _stopSessions() async {
    final sessions = List<LspSession>.from(_sessions.values);
    _sessions.clear();
    for (final session in sessions) {
      try {
        await session.stop();
      } catch (e) {
        debugPrint('停止语言服务失败：$e');
      }
    }
  }

  void _setState(LspManagerState value) {
    state = value;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopSessions());
    super.dispose();
  }
}
