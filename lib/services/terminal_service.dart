import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'container_service.dart';

/// 命令执行结果
class ShellResult {
  final int exitCode;
  final String cwd;

  const ShellResult({required this.exitCode, required this.cwd});

  bool get isSuccess => exitCode == 0;
}

/// 持久 shell 会话
///
/// 通过 proot 启动一个常驻的 `/bin/sh`，逐行写入命令，
/// 并利用哨兵标记（exit code + 当前目录）判断命令结束。
class TerminalSession {
  TerminalSession._(this._process);

  final Process _process;
  final StreamController<String> _outputController =
      StreamController<String>.broadcast();

  Completer<ShellResult>? _pending;

  String cwd = '/root';
  bool _closed = false;

  static const String _marker = '@@SLIPCODE_DONE@@';

  Stream<String> get output => _outputController.stream;
  bool get isClosed => _closed;
  bool get isBusy => _pending != null;

  /// 启动会话
  ///
  /// [projectDir] 宿主项目目录，将挂载为 /workspace
  static Future<TerminalSession> start({String? projectDir}) async {
    final process = await ContainerService.instance.startShell(projectDir: projectDir);
    final session = TerminalSession._(process);

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(session._handleLine, onError: session._handleError);

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          session._emit(line);
        }, onError: session._handleError);

    process.exitCode.then((code) {
      session._closed = true;
      session._emit('[进程已退出，code=$code]');
      final pending = session._pending;
      if (pending != null && !pending.isCompleted) {
        pending.complete(const ShellResult(exitCode: -1, cwd: '/root'));
        session._pending = null;
      }
      if (!session._outputController.isClosed) {
        session._outputController.close();
      }
    });

    return session;
  }

  void _emit(String line) {
    if (!_outputController.isClosed) {
      _outputController.add(line);
    }
  }

  void _handleError(Object error) {
    _emit('[流错误] $error');
  }

  void _handleLine(String line) {
    // 哨兵格式：@@SLIPCODE_DONE@@<exitCode>@@<cwd>
    if (line.startsWith(_marker)) {
      final payload = line.substring(_marker.length);
      final parts = payload.split('@@');
      final exitCode = int.tryParse(parts.isNotEmpty ? parts[0].trim() : '') ?? -1;
      if (parts.length > 1 && parts[1].isNotEmpty) {
        cwd = parts[1].trim();
      }
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        pending.complete(ShellResult(exitCode: exitCode, cwd: cwd));
        _pending = null;
      }
      return;
    }
    _emit(line);
  }

  /// 执行一条命令，等待执行结束
  Future<ShellResult> run(String command, {Duration? timeout}) async {
    if (_closed) {
      throw StateError('会话已关闭');
    }
    if (_pending != null) {
      throw StateError('上一条命令仍在执行中');
    }

    final completer = Completer<ShellResult>();
    _pending = completer;

    _emit('\$ $command');

    _process.stdin.writeln(command);
    // 输出结束哨兵：换行 + 退出码 + 当前目录
    _process.stdin.writeln(
      "printf '\\n@@SLIPCODE_DONE@@%s@@%s\\n' \"\$?\" \"\$PWD\"",
    );
    await _process.stdin.flush();

    if (timeout != null) {
      return completer.future.timeout(timeout, onTimeout: () {
        _pending = null;
        _emit('[命令超时，已忽略]');
        return const ShellResult(exitCode: -1, cwd: '/root');
      });
    }
    return completer.future;
  }

  /// 向进程写入原始输入（用于需要交互的命令）
  Future<void> writeRaw(String input) async {
    if (_closed) return;
    _process.stdin.writeln(input);
    await _process.stdin.flush();
  }

  Future<void> dispose() async {
    _closed = true;
    try {
      await _process.stdin.close();
    } catch (_) {}
    _process.kill();
  }
}
