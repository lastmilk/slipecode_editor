import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'desktop_platform.dart';
import 'desktop_prefs_service.dart';
import 'toolchain/toolchain_manager.dart';

/// 一次命令执行的结果
class TerminalRunResult {
  const TerminalRunResult({
    required this.sessionId,
    required this.output,
    required this.running,
    required this.timedOut,
    this.exitCode,
  });

  /// 执行命令的会话 id
  final String sessionId;

  /// 命令输出（已去掉内部完成标记）
  final String output;

  /// 命令是否仍在运行
  final bool running;

  /// 是否因为没有在超时时间内结束而返回
  final bool timedOut;

  /// 命令退出码；仍在运行时为 null
  final int? exitCode;
}

/// 读取会话输出的结果
class TerminalReadResult {
  const TerminalReadResult({
    required this.sessionId,
    required this.output,
    required this.running,
    this.exitCode,
    this.hasNewOutput = true,
  });

  final String sessionId;
  final String output;
  final bool running;
  final int? exitCode;
  final bool hasNewOutput;
}

/// 一个独立的终端会话（PTY + xterm 缓冲区）。
class TerminalSession {
  TerminalSession({
    required this.id,
    required this.title,
    required this.shell,
    required this.terminal,
    this.workingDirectory,
    this.aiSession = false,
  });

  final String id;
  final Terminal terminal;
  final String shell;
  final bool aiSession;

  String title;
  String? workingDirectory;

  Pty? pty;
  StreamSubscription<String>? _outputSub;

  bool running = false;
  int? exitCode;

  /// 是否有 AI 命令正在该会话中等待结束
  bool busy = false;

  /// 正在执行的 AI 命令的完成标记 nonce
  String? activeNonce;

  /// 最近一次 AI 开始执行命令时的绝对偏移
  int aiReadOffset = 0;

  DateTime createdAt = DateTime.now();
  DateTime lastActivity = DateTime.now();

  /// 输出缓冲上限（字符）
  static const int maxBufferChars = 200000;

  final StringBuffer _buffer = StringBuffer();
  int _trimmedChars = 0;

  int get absoluteLength => _trimmedChars + _buffer.length;

  String get bufferText => _buffer.toString();

  void append(String data) {
    _buffer.write(data);
    final total = _trimmedChars + _buffer.length;
    if (total > maxBufferChars) {
      final text = _buffer.toString();
      final remove = total - maxBufferChars;
      _trimmedChars += remove;
      _buffer.clear();
      _buffer.write(text.substring(remove));
    }
    lastActivity = DateTime.now();
  }

  /// 取绝对偏移 [abs] 之后的文本
  String sliceFromAbsolute(int abs) {
    final text = _buffer.toString();
    final relative = abs - _trimmedChars;
    if (relative <= 0) return text;
    if (relative >= text.length) return '';
    return text.substring(relative);
  }

  /// 取尾部 [maxChars] 个字符
  String tail(int maxChars) {
    final text = _buffer.toString();
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }

  void cancelOutputSub() {
    unawaited(_outputSub?.cancel());
    _outputSub = null;
  }

  void attachOutput(StreamSubscription<String> sub) {
    _outputSub = sub;
  }
}

/// 桌面嵌入式终端服务（PTY）。
///
/// 支持多个并行会话：
/// - 用户通过底部面板创建 / 切换 / 结束终端；
/// - AI 通过 [runCommand] 执行命令，超时后返回「仍在运行」的会话，
///   可继续用 [sendInput] / [readOutput] / [killSession] 操作。
///
/// 全局单例：面板折叠再展开时保留会话；切换项目时重建会话。
class DesktopTerminalService extends ChangeNotifier {
  DesktopTerminalService._();

  static final DesktopTerminalService instance = DesktopTerminalService._();

  final List<TerminalSession> _sessions = [];
  String? _activeId;
  int _seq = 0;
  int _aiSeq = 0;
  Timer? _notifyTimer;

  static const String _markerPrefix = '@@SLIPE_DONE:';

  // ---------------------------------------------------------------------------
  // 会话访问
  // ---------------------------------------------------------------------------

  List<TerminalSession> get sessions => List.unmodifiable(_sessions);

  String? get activeSessionId => _activeId;

  TerminalSession? get activeSession {
    final id = _activeId;
    if (id == null) return null;
    return _sessionById(id);
  }

  /// 兼容旧调用点：当前会话的 xterm 终端
  Terminal? get terminal => activeSession?.terminal;

  String? get shell => activeSession?.shell;

  bool get isRunning => activeSession?.running ?? false;

  int? get exitCode => activeSession?.exitCode;

  bool get hasSessions => _sessions.isNotEmpty;

  TerminalSession? _sessionById(String? id) {
    if (id == null) return null;
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  TerminalSession? sessionOf(String? id) => _sessionById(id);

  void setActive(String id) {
    if (_sessionById(id) == null || _activeId == id) return;
    _activeId = id;
    _notify();
  }

  void _notify() {
    // 合并高频输出通知，避免每个字节都触发整棵面板重建。
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 80), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  // ---------------------------------------------------------------------------
  // 创建 / 关闭
  // ---------------------------------------------------------------------------

  /// 新建一个终端会话并激活，返回会话。
  Future<TerminalSession> createSession({
    String? title,
    String? shellPath,
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 24,
    int columns = 80,
    bool aiSession = false,
  }) async {
    final shell = (shellPath ?? DesktopPrefsService.instance.effectiveShell)
        .trim();
    final terminal = Terminal(maxLines: 5000);
    final session = TerminalSession(
      id: 'term-${DateTime.now().microsecondsSinceEpoch}-${++_seq}',
      title: title ?? (aiSession ? 'AI 终端 ${++_aiSeq}' : '终端 ${_seq + 1}'),
      shell: shell,
      terminal: terminal,
      workingDirectory: workingDirectory,
      aiSession: aiSession,
    );
    _sessions.add(session);
    _activeId = session.id;

    terminal.onOutput = (data) {
      session.pty?.write(Uint8List.fromList(utf8.encode(data)));
    };
    terminal.onResize = (width, height, _, __) {
      session.pty?.resize(height, width);
    };

    try {
      final env =
          environment ??
          ToolchainManager.instance
              .environment(projectPath: workingDirectory)
              .build();
      final pty = Pty.start(
        shell,
        workingDirectory: workingDirectory,
        environment: env,
        rows: rows,
        columns: columns,
      );
      session.pty = pty;
      session.running = true;
      session.attachOutput(
        const Utf8Decoder(allowMalformed: true).bind(pty.output).listen((data) {
          session.append(data);
          session.terminal.write(data);
          _notify();
        }),
      );
      unawaited(
        pty.exitCode.then((code) {
          session
            ..exitCode = code
            ..running = false
            ..busy = false;
          session.terminal.write('\r\n\x1b[90m[进程已退出，code=$code]\x1b[0m\r\n');
          _notify();
        }),
      );
    } catch (e) {
      session
        ..running = false
        ..exitCode = -1;
      session.terminal.write('启动终端失败：$e\r\n');
      debugPrint('启动 PTY 失败：$e');
    }
    _notify();
    return session;
  }

  /// 兼容旧调用：关闭当前会话并在项目目录新建一个。
  Future<void> start({
    String? shellPath,
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 24,
    int columns = 80,
  }) async {
    final previous = activeSession;
    final title = previous?.title;
    final shell = shellPath ?? previous?.shell;
    final cwd = workingDirectory ?? previous?.workingDirectory;
    if (previous != null) await closeSession(previous.id);
    await createSession(
      title: title,
      shellPath: shell,
      workingDirectory: cwd,
      environment: environment,
      rows: rows,
      columns: columns,
    );
  }

  /// 在项目目录重启当前会话。
  Future<void> restart() async {
    final session = activeSession;
    await start(
      shellPath: session?.shell,
      workingDirectory: session?.workingDirectory,
    );
  }

  /// 结束会话进程但保留会话与历史输出。
  Future<void> stopSession(String id) async {
    final session = _sessionById(id);
    if (session == null) return;
    await _killPty(session);
    session
      ..running = false
      ..busy = false;
    _notify();
  }

  /// 结束并移除会话。
  Future<void> closeSession(String id) async {
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    final session = _sessions.removeAt(index);
    session.cancelOutputSub();
    await _killPty(session);
    if (_activeId == id) {
      _activeId = _sessions.isEmpty
          ? null
          : _sessions[min(index, _sessions.length - 1)].id;
    }
    _notify();
  }

  /// 兼容旧调用：结束当前会话。
  Future<void> stop() async {
    final session = activeSession;
    if (session == null) return;
    await closeSession(session.id);
  }

  Future<void> _killPty(TerminalSession session) async {
    final pty = session.pty;
    session.pty = null;
    if (pty == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/T', '/F', '/PID', '${pty.pid}']);
      } else {
        pty.kill(ProcessSignal.sigterm);
      }
    } catch (e) {
      debugPrint('关闭终端失败：$e');
    }
  }

  /// 关闭全部会话（切换项目 / 退出时使用）。
  Future<void> closeAll() async {
    for (final session in _sessions.toList()) {
      await closeSession(session.id);
    }
  }

  // ---------------------------------------------------------------------------
  // 交互
  // ---------------------------------------------------------------------------

  /// 向指定会话写入原始字符串。
  void writeTo(String id, String data) {
    final session = _sessionById(id);
    if (session == null) return;
    session.pty?.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// 向当前会话写入原始字符串。
  void write(String data) {
    final session = activeSession;
    if (session == null) return;
    session.pty?.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// 向会话发送输入（供 AI 应答 y/n、填写内容或按组合键）。
  ///
  /// [input] 支持 [enter] 自动回车，也支持常见组合键别名。
  bool sendInput(String id, String input, {bool enter = true}) {
    final session = _sessionById(id);
    if (session == null || session.pty == null || !session.running) {
      return false;
    }
    final data = _resolveInput(input, enter: enter);
    if (data.isEmpty) return false;
    session.pty!.write(Uint8List.fromList(utf8.encode(data)));
    session.lastActivity = DateTime.now();
    return true;
  }

  String _resolveInput(String input, {required bool enter}) {
    final trimmed = input.trim();
    final lower = trimmed.toLowerCase();
    const keys = <String, String>{
      'ctrl+c': '\x03',
      'ctrl-c': '\x03',
      '^c': '\x03',
      'ctrl+d': '\x04',
      'ctrl-d': '\x04',
      '^d': '\x04',
      'ctrl+z': '\x1a',
      '^z': '\x1a',
      'esc': '\x1b',
      'escape': '\x1b',
      'tab': '\t',
      'enter': '\r',
      'return': '\r',
      'space': ' ',
      'up': '\x1b[A',
      'down': '\x1b[B',
      'right': '\x1b[C',
      'left': '\x1b[D',
      'backspace': '\x7f',
    };
    if (keys.containsKey(lower)) return keys[lower]!;
    final normalized = input.replaceAll('\r\n', '\n');
    final buffer = StringBuffer();
    for (final line in normalized.split('\n')) {
      buffer.write(line);
      buffer.write('\r');
    }
    if (!enter) {
      // 去掉最后自动追加的回车
      final text = buffer.toString();
      return text.endsWith('\r') ? text.substring(0, text.length - 1) : text;
    }
    return buffer.toString();
  }

  void resize(int rows, int columns) {
    activeSession?.pty?.resize(rows, columns);
  }

  void clear() {
    activeSession?.terminal.write('\x1b[2J\x1b[H');
  }

  /// 兼容旧接口：在项目目录执行命令并返回文本（无会话感知）。
  Future<String> executeForAi(String command) async {
    final result = await runCommand(
      command,
      timeout: const Duration(minutes: 2),
    );
    final buffer = StringBuffer(result.output.trimRight());
    if (result.running) {
      buffer.writeln(
        '\n[命令仍在运行，会话 ${result.sessionId}]'
        '可继续用 terminal_read / terminal_send_input 操作。',
      );
    } else {
      buffer.writeln('\n退出码：${result.exitCode}');
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // AI 命令执行
  // ---------------------------------------------------------------------------

  /// 执行一条命令。
  ///
  /// 未指定 [sessionId] 时自动复用空闲的 AI 会话；若该会话仍有命令在跑，
  /// 则新建 AI 会话，避免两条命令互相干扰。
  Future<TerminalRunResult> runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    String? sessionId,
    bool newSession = false,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    TerminalSession? session = _sessionById(sessionId);
    var createdNew = false;
    if (session == null && !newSession) {
      for (final item in _sessions.reversed) {
        if (item.aiSession && !item.busy && item.running) {
          session = item;
          break;
        }
      }
    }
    if (session == null) {
      session = await createSession(
        workingDirectory: workingDirectory,
        environment: environment,
        aiSession: true,
      );
      createdNew = true;
    }
    if (session.busy && sessionId != null) {
      return TerminalRunResult(
        sessionId: session.id,
        output:
            '该终端仍在执行上一条命令。请先用 terminal_read 查看输出、'
            'terminal_send_input 发送输入，或新建终端后再执行。',
        running: true,
        timedOut: false,
      );
    }
    if (createdNew) {
      final firstLine = command.trim().split('\n').first.trim();
      session.title =
          'AI · ${firstLine.length > 22 ? '${firstLine.substring(0, 22)}…' : firstLine}';
    }

    final startAbs = session.absoluteLength;
    session.aiReadOffset = startAbs;
    final nonce = '${DateTime.now().microsecondsSinceEpoch}';
    final wrapped = _wrapCommand(command, nonce);
    if (session.pty == null || !session.running) {
      final hint = session.bufferText.trim();
      return TerminalRunResult(
        sessionId: session.id,
        output: hint.isEmpty ? '终端进程未启动，无法执行命令。请检查 shell 配置后新建终端。' : hint,
        running: false,
        timedOut: false,
        exitCode: session.exitCode ?? -1,
      );
    }
    session.busy = true;
    session.activeNonce = nonce;
    session.pty?.write(Uint8List.fromList(utf8.encode('$wrapped\r')));

    final deadline = DateTime.now().add(timeout);
    int? exit;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      exit = _parseExitCode(session.bufferText, nonce);
      if (exit != null) break;
      if (!session.running) {
        exit = session.exitCode ?? -1;
        break;
      }
    }

    final raw = session.sliceFromAbsolute(startAbs);
    final output = _stripMarker(raw, nonce);
    if (exit != null) {
      session
        ..busy = false
        ..activeNonce = null
        ..exitCode = exit;
      session.aiReadOffset = session.absoluteLength;
    }
    _notify();
    return TerminalRunResult(
      sessionId: session.id,
      output: output,
      running: exit == null,
      timedOut: exit == null,
      exitCode: exit,
    );
  }

  String _wrapCommand(String command, String nonce) {
    if (Platform.isWindows) {
      final shell = DesktopPlatform.defaultShell.toLowerCase();
      if (shell.contains('powershell') || shell.contains('pwsh')) {
        return '$command\r\n'
            'Write-Output "$_markerPrefix$nonce:\$LASTEXITCODE"';
      }
      return '$command\r\necho $_markerPrefix$nonce:%ERRORLEVEL%';
    }
    return '$command\n'
        "printf '\\033]2;$_markerPrefix$nonce:%s\\007' \"\$?\"";
  }

  int? _parseExitCode(String text, String nonce) {
    final posix = RegExp(
      '\\x1b\\]2;${RegExp.escape(_markerPrefix)}$nonce:(-?\\d+)\\x07',
    ).firstMatch(text);
    if (posix != null) return int.tryParse(posix.group(1) ?? '');
    final plain = RegExp('${RegExp.escape(_markerPrefix)}$nonce:(-?\\d+)')
        .firstMatch(text);
    return int.tryParse(plain?.group(1) ?? '');
  }

  String _stripMarker(String text, String nonce) {
    return text
        .replaceAll(
          RegExp('\\x1b\\]2;${RegExp.escape(_markerPrefix)}$nonce:-?\\d+\\x07'),
          '',
        )
        // 去掉 shell 回显的 printf / echo 完成标记行
        .replaceAll(
          RegExp('[^\\r\\n]*${RegExp.escape(_markerPrefix)}[^\\r\\n]*'),
          '',
        );
  }

  /// 读取会话从上次 AI 读取位置之后的新输出。
  TerminalReadResult readOutput(
    String sessionId, {
    int maxChars = 12000,
    bool consume = true,
  }) {
    final session = _sessionById(sessionId);
    if (session == null) {
      return TerminalReadResult(
        sessionId: sessionId,
        output: '错误：会话不存在 $sessionId',
        running: false,
      );
    }
    // 检查迟到的完成标记
    final nonce = session.activeNonce;
    final pending = nonce == null
        ? null
        : _parseExitCode(session.bufferText, nonce);
    if (pending != null) {
      session
        ..busy = false
        ..activeNonce = null
        ..exitCode = pending;
    }
    var text = session.sliceFromAbsolute(session.aiReadOffset);
    final hasNew = text.trim().isNotEmpty;
    if (!hasNew) {
      text = session.tail(maxChars);
    } else if (text.length > maxChars) {
      text = text.substring(text.length - maxChars);
    }
    if (consume) session.aiReadOffset = session.absoluteLength;
    return TerminalReadResult(
      sessionId: session.id,
      output: text,
      running: session.running,
      exitCode: session.exitCode,
      hasNewOutput: hasNew,
    );
  }

  /// 等待会话结束；返回是否已结束。
  Future<bool> waitForExit(
    String sessionId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final session = _sessionById(sessionId);
    if (session == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!session.running) return true;
      final nonce = session.activeNonce;
      final marker = nonce == null
          ? null
          : _parseExitCode(session.bufferText, nonce);
      if (marker != null) {
        session
          ..busy = false
          ..activeNonce = null
          ..exitCode = marker;
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return !session.running;
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    unawaited(closeAll());
    super.dispose();
  }
}
