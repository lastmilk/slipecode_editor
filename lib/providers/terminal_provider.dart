import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';

/// 终端状态管理
///
/// 移动端（Android / iOS）不提供本地终端（原 Termux 方案已下线，
/// 构建请使用云端 GitHub Actions / Gitee Go）。
/// 桌面端（Linux / macOS / Windows）使用系统 shell 执行命令。
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
  String get cwd =>
      _cwd.isNotEmpty ? _cwd : (_projectDir ?? Directory.current.path);
  bool get starting => _starting;
  bool get running => _running;
  bool get isReady => _ready;
  bool get busy => _starting || _running;
  String? get error => _error;
  int? get lastExitCode => _lastExitCode;

  /// 当前平台是否支持本地终端（仅桌面端）
  bool get supported =>
      !Platform.isAndroid && !Platform.isIOS && !Platform.isFuchsia;

  /// 当前环境是否可以展示终端入口（与 [supported] 一致，仅桌面端）
  bool get available => supported;

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
  ///
  /// 切换项目时会把 cwd 重置到新项目路径，保证「在对应项目中打开终端」
  /// 会自动 cd 到该项目的存储路径。
  void setProjectDir(String? dir) {
    if (dir == _projectDir) return;
    _projectDir = dir;
    if (dir != null && dir.isNotEmpty) {
      _cwd = dir;
    }
  }

  /// 确保终端环境可用（桌面端直接使用系统 shell）
  Future<bool> ensureStarted() async {
    if (_ready) return true;
    if (_starting) return false;

    _starting = true;
    _error = null;
    _safeNotify();

    try {
      if (!supported) {
        _error = t('terminal.unsupported');
        _append(t('terminal.unsupportedLog'));
        _ready = false;
        return false;
      }

      if (_cwd.isEmpty) _cwd = _projectDir ?? Directory.current.path;
      _ready = true;
      _append(t('terminal.readyLog', {'cwd': _cwd}));
      return true;
    } catch (e) {
      _error = '$e';
      _append(t('terminal.startFailedLog', {'error': '$e'}));
      _ready = false;
      return false;
    } finally {
      _starting = false;
      _safeNotify();
    }
  }

  /// 供 AI 工具调用：在项目目录执行命令并返回文本结果
  Future<String> executeForAi(String command) async {
    if (!await ensureStarted()) {
      return t('terminal.aiNotReady', {'error': _error ?? t('terminal.unsupported')});
    }
    final result = await _execute(command);
    final output = StringBuffer();
    if (result.out.trim().isNotEmpty) output.writeln(result.out.trimRight());
    if (result.err.trim().isNotEmpty) output.writeln(result.err.trimRight());
    output.writeln(t('terminal.exitCode', {'code': '${result.exitCode}'}));
    return output.toString();
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
      _append(t('terminal.execFailedLog', {'error': '$e'}));
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
    _append(t('terminal.resetLog'));
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
