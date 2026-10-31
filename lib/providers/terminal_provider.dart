import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/termux_service.dart';

/// 终端状态管理
///
/// 不再依赖 proot 容器：只要设备安装了 Termux，即可通过
/// `com.termux.app.RunCommandService` 执行命令。
/// 非移动平台（桌面 Linux/macOS）使用系统 shell 兜底。
class TerminalProvider extends ChangeNotifier {
  static const String _cwdMarker = '@@SLIPE_CWD@@';

  final List<String> _lines = [];
  String _cwd = '';
  String? _projectDir;

  bool _starting = false;
  bool _running = false;
  bool _ready = false;
  String? _error;
  int? _lastExitCode;

  bool _disposed = false;

  List<String> get lines => List.unmodifiable(_lines);
  String get cwd => _cwd.isNotEmpty
      ? _cwd
      : (_projectDir ?? (Platform.isAndroid ? '/data/data/com.termux/files/home' : '/'));
  bool get starting => _starting;
  bool get running => _running;
  bool get isReady => _ready;
  bool get busy => _starting || _running;
  String? get error => _error;
  int? get lastExitCode => _lastExitCode;

  /// 当前平台是否支持终端
  bool get supported => !Platform.isIOS;

  /// Android 上需要安装 Termux
  bool get needsTermux => Platform.isAndroid;

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

  /// 设置当前项目目录（作为终端的初始工作目录）
  void setProjectDir(String? dir) {
    _projectDir = dir;
    if (dir != null && dir.isNotEmpty && _cwd.isEmpty) {
      _cwd = dir;
    }
  }

  /// 确保终端环境可用（Android 检查 Termux 是否安装）
  Future<bool> ensureStarted() async {
    if (_ready) return true;
    if (_starting) return false;

    _starting = true;
    _error = null;
    _safeNotify();

    try {
      if (Platform.isAndroid) {
        final installed = await TermuxService.instance.isTermuxInstalled();
        if (!installed) {
          _error = '未检测到 Termux，请先安装 Termux（无需 proot 容器）';
          _append('[未检测到 Termux] 请安装 Termux 后重试；本终端不依赖 proot 容器。');
          _ready = false;
          return false;
        }
        if (_cwd.isEmpty) _cwd = _projectDir ?? '/data/data/com.termux/files/home';
        _ready = true;
        _append('[Termux 终端已就绪，cwd=$_cwd]');
      } else if (Platform.isIOS) {
        _error = 'iOS 不支持调用外部终端';
        _append('[当前平台不支持终端] iOS 无法启动 Termux / 系统 shell。');
        _ready = false;
        return false;
      } else {
        if (_cwd.isEmpty) _cwd = _projectDir ?? Directory.current.path;
        _ready = true;
        _append('[本地 shell 已就绪，cwd=$_cwd]');
      }
      return true;
    } catch (e) {
      _error = '$e';
      _append('[终端启动失败] $e');
      _ready = false;
      return false;
    } finally {
      _starting = false;
      _safeNotify();
    }
  }

  /// 执行命令
  Future<void> runCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) return;
    if (busy) return;

    if (!_ready) {
      final ok = await ensureStarted();
      if (!ok) return;
    }

    _running = true;
    _error = null;
    _append('\$ $cmd');
    _safeNotify();

    try {
      final result = await _execute(cmd);
      _lastExitCode = result.exitCode;

      final stdout = _extractCwd(result.out);
      _appendOutput(stdout.output);
      _appendOutput(result.err);
      if (stdout.cwd.isNotEmpty) {
        _cwd = stdout.cwd;
      }
    } catch (e) {
      _error = '$e';
      _append('[执行失败] $e');
    } finally {
      _running = false;
      _safeNotify();
    }
  }

  void _appendOutput(String text) {
    final trimmed = text.replaceAll('\r\n', '\n').trimRight();
    if (trimmed.isEmpty) return;
    for (final line in trimmed.split('\n')) {
      _append(line);
    }
  }

  /// 把命令包成「先 cd 到当前目录，再执行，最后打印 PWD」
  Future<({int exitCode, String out, String err})> _execute(String cmd) async {
    if (Platform.isAndroid) {
      final script = 'cd ${_shellQuote(cwd)} 2>/dev/null; $cmd\n'
          'printf "\\n$_cwdMarker%s\\n" "\$PWD"';
      final result = await TermuxService.instance.exec(script);
      return (
        exitCode: result.exitCode,
        out: result.stdout,
        err: result.stderr,
      );
    }

    if (Platform.isWindows) {
      final result = await Process.run(
        'cmd',
        ['/c', cmd],
        workingDirectory: cwd,
        runInShell: false,
      );
      return (
        exitCode: result.exitCode,
        out: '${result.stdout}',
        err: '${result.stderr}',
      );
    }

    final script = 'cd ${_shellQuote(cwd)} 2>/dev/null; $cmd\n'
        'printf "\\n$_cwdMarker%s\\n" "\$PWD"';
    final result = await Process.run(
      '/bin/sh',
      ['-c', script],
      workingDirectory: cwd,
    );
    return (
      exitCode: result.exitCode,
      out: '${result.stdout}',
      err: '${result.stderr}',
    );
  }

  ({String output, String cwd}) _extractCwd(String raw) {
    final index = raw.lastIndexOf(_cwdMarker);
    if (index < 0) return (output: raw, cwd: '');
    final rest = raw.substring(index + _cwdMarker.length);
    final newline = rest.indexOf('\n');
    final newCwd = (newline >= 0 ? rest.substring(0, newline) : rest).trim();
    return (output: raw.substring(0, index), cwd: newCwd);
  }

  String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  /// 重启（重置环境检查状态）
  Future<void> restart() async {
    _ready = false;
    _error = null;
    _cwd = _projectDir ?? '';
    _lastExitCode = null;
    _append('[已重置终端会话]');
    await ensureStarted();
  }

  /// 清空输出
  void clear() {
    _lines.clear();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
