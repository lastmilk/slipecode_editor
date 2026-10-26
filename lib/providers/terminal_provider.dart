import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/terminal_service.dart';

/// 终端状态管理
///
/// 维护一个常驻 proot shell 会话，用于项目命令行操作
class TerminalProvider extends ChangeNotifier {
  TerminalSession? _session;
  StreamSubscription<String>? _subscription;

  final List<String> _lines = [];
  String _cwd = '/root';

  bool _starting = false;
  bool _running = false;
  String? _error;
  int? _lastExitCode;

  bool _disposed = false;
  String? _projectDir;

  List<String> get lines => List.unmodifiable(_lines);
  String get cwd => _cwd;
  bool get starting => _starting;
  bool get running => _running;
  bool get isReady => _session != null && !_session!.isClosed;
  bool get busy => _starting || _running;
  String? get error => _error;
  int? get lastExitCode => _lastExitCode;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _append(String line) {
    _lines.add(line);
    if (_lines.length > 3000) {
      _lines.removeRange(0, _lines.length - 3000);
    }
    _safeNotify();
  }

  /// 设置当前项目目录（用于挂载 /workspace）
  void setProjectDir(String? dir) {
    _projectDir = dir;
  }

  /// 确保会话已启动
  Future<bool> ensureStarted() async {
    if (isReady) return true;
    if (_starting) return false;

    _starting = true;
    _error = null;
    _safeNotify();

    try {
      _append('[正在启动 proot 容器会话...]');
      final session = await TerminalSession.start(projectDir: _projectDir);
      _session = session;
      _cwd = session.cwd;

      _subscription = session.output.listen(
        (line) => _append(line),
        onDone: () {
          _append('[会话结束]');
          _safeNotify();
        },
        onError: (Object e) => _append('[会话错误] $e'),
      );

      _append('[容器会话已就绪，cwd=${session.cwd}]');
      _starting = false;
      _running = false;
      _safeNotify();
      return true;
    } catch (e) {
      _starting = false;
      _error = '$e';
      _append('[启动失败] $e');
      _safeNotify();
      return false;
    }
  }

  /// 执行命令
  Future<void> runCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) return;

    if (!isReady) {
      final ok = await ensureStarted();
      if (!ok) return;
    }

    _running = true;
    _error = null;
    _safeNotify();

    try {
      final result = await _session!.run(cmd);
      _lastExitCode = result.exitCode;
      _cwd = result.cwd;
    } catch (e) {
      _error = '$e';
      _append('[执行失败] $e');
    } finally {
      _running = false;
      _safeNotify();
    }
  }

  /// 重启会话
  Future<void> restart() async {
    await _stopSession();
    await ensureStarted();
  }

  Future<void> _stopSession() async {
    await _subscription?.cancel();
    _subscription = null;
    await _session?.dispose();
    _session = null;
  }

  /// 清空输出
  void clear() {
    _lines.clear();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _session?.dispose();
    super.dispose();
  }
}
