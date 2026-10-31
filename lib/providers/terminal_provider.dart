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

  // Termux 环境探测结果（仅在 Android 上有意义）
  bool _detected = false;
  bool _termuxInstalled = false;
  bool _termuxApiInstalled = false;
  bool _permissionGranted = false;
  bool _allowExternalAppsOk = true;

  bool _disposed = false;

  /// Termux 未就绪时需用户在 Termux 内执行的配置命令
  static const List<String> termuxSetupCommands = [
    'pkg install termux-api',
    'if ! grep -q "allow-external-apps" ~/.termux/termux.properties 2>/dev/null; then\n'
        '    cat >> ~/.termux/termux.properties << \'EOF\'\n'
        'allow-external-apps=true\n'
        'EOF\n'
        'fi',
    'termux-reload-settings',
    'termux-setup-storage',
  ];

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

  /// 是否已检测过 Termux 环境
  bool get detected => _detected;

  /// Termux 是否已安装
  bool get termuxInstalled => _termuxInstalled;

  /// Termux:API 是否已安装
  bool get termuxApiInstalled => _termuxApiInstalled;

  /// 是否已获得 Termux 命令执行权限
  bool get permissionGranted => _permissionGranted;

  /// Termux 的 allow-external-apps 是否已开启（探测失败时为 false）
  bool get allowExternalAppsOk => _allowExternalAppsOk;

  /// 当前平台是否支持终端
  bool get supported => !Platform.isIOS;

  /// 当前环境是否可以展示终端入口
  ///
  /// Android 上必须检测到 Termux，桌面端默认可用，iOS 不可用。
  bool get available {
    if (Platform.isIOS) return false;
    if (Platform.isAndroid) return _termuxInstalled;
    return true;
  }

  /// Android 上需要安装 Termux
  bool get needsTermux => Platform.isAndroid && !_termuxInstalled;

  /// 是否需要在 Termux 中执行配置命令
  bool get needsSetup =>
      Platform.isAndroid &&
      _termuxInstalled &&
      (!_permissionGranted || !_allowExternalAppsOk);

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

  /// 检测 Termux / Termux:API 安装与运行时权限状态
  Future<void> detectTermux() async {
    if (!Platform.isAndroid) {
      _detected = true;
      _safeNotify();
      return;
    }
    _termuxInstalled = await TermuxService.instance.isTermuxInstalled();
    _termuxApiInstalled = await TermuxService.instance.isTermuxApiInstalled();
    _permissionGranted =
        await TermuxService.instance.hasRunCommandPermission();
    _detected = true;
    _safeNotify();
  }

  /// 申请 Termux 命令执行权限（系统弹窗）
  Future<bool> requestTermuxPermission() async {
    _permissionGranted =
        await TermuxService.instance.requestRunCommandPermission();
    _safeNotify();
    return _permissionGranted;
  }

  /// 打开 Termux 应用（便于用户执行配置命令）
  Future<void> openTermux() => TermuxService.instance.openTermux();

  /// 打开 Termux:API 应用
  Future<void> openTermuxApi() => TermuxService.instance.openTermuxApi();

  /// 确保终端环境可用（Android 检查 Termux 安装与权限）
  Future<bool> ensureStarted() async {
    if (_ready) return true;
    if (_starting) return false;

    _starting = true;
    _error = null;
    _safeNotify();

    try {
      if (Platform.isAndroid) {
        if (!_detected) await detectTermux();
        if (!_termuxInstalled) {
          _error = '未检测到 Termux，请先安装 Termux（无需 proot 容器）';
          _append('[未检测到 Termux] 请安装 Termux 后重试；本终端不依赖 proot 容器。');
          _ready = false;
          return false;
        }

        // Termux 的 RUN_COMMAND 是 dangerous 权限，需要运行时授权
        if (!_permissionGranted) {
          _permissionGranted =
              await TermuxService.instance.requestRunCommandPermission();
        }
        if (!_permissionGranted) {
          _error = '未授予 Termux 命令执行权限，请在系统弹窗中允许';
          _append(
            '[未授予 Termux 权限] 请点击「申请权限」并在系统弹窗中选择允许。',
          );
          _ready = false;
          return false;
        }

        // 探测实际可执行性（可发现 allow-external-apps 未开启等问题）
        final probe = await TermuxService.instance.probe();
        _allowExternalAppsOk = probe.ok;
        if (!probe.ok) {
          _error = probe.message;
          _append('[Termux 未就绪] ${probe.message}');
          _append('[请在 Termux 中依次执行以下命令]');
          for (var i = 0; i < termuxSetupCommands.length; i++) {
            _append('${i + 1}. ${termuxSetupCommands[i]}');
          }
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

  /// 供 AI 工具调用：在项目目录执行命令并返回文本结果
  Future<String> executeForAi(String command) async {
    if (!await ensureStarted()) {
      return '错误：${_error ?? '终端未就绪'}';
    }
    final result = await _execute(command);
    final output = StringBuffer();
    if (result.out.trim().isNotEmpty) output.writeln(result.out.trimRight());
    if (result.err.trim().isNotEmpty) output.writeln(result.err.trimRight());
    output.writeln('退出码：${result.exitCode}');
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
