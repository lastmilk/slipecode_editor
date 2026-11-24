import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_info.dart';
import 'crash_analyzer.dart';
import 'crash_log_service.dart';
import 'desktop_platform.dart';
import 'launch_args.dart';

enum EditorLaunchStatus {
  /// 已成功拉起新的编辑器进程
  launched,

  /// 该项目已经在编辑器中打开
  alreadyRunning,

  /// 当前平台不支持多进程（移动端）
  unsupported,

  /// 拉起失败
  failed,
}

class EditorLaunchResult {
  const EditorLaunchResult(this.status, [this.message = '']);

  final EditorLaunchStatus status;
  final String message;

  bool get ok =>
      status == EditorLaunchStatus.launched ||
      status == EditorLaunchStatus.alreadyRunning;
}

/// 编辑器子进程服务（仅桌面端）
///
/// Hub 通过 `slipe_editor --role=editor --project=<path>` 拉起独立进程：
/// - 独立地址空间与崩溃域：编辑器崩溃不会带走 Hub
/// - 窗口互斥：Hub 随后隐藏（保存进程与崩溃捕获）或退出（detached 启动）
/// - Hub 捕获子进程输出，异常退出时弹出「SLIPE 异常窗口」
class EditorProcessService {
  EditorProcessService._();

  static final EditorProcessService instance = EditorProcessService._();

  final Map<String, _EditorProcess> _processes = {};

  /// 编辑器异常退出时的回调（由 Hub 注册，用于弹出异常窗口）
  void Function(EditorCrashReport report)? onCrash;

  /// 所有编辑器窗口都已关闭时的回调（由 Hub 注册，用于恢复 Hub 窗口）
  void Function()? onAllClosed;

  /// 是否支持独立进程（桌面端）
  bool get supported => DesktopPlatform.isDesktop;

  bool isRunning(String projectPath) =>
      _processes[projectPath]?.process != null;

  /// 打开项目：桌面端拉起独立进程；移动端返回 [EditorLaunchStatus.unsupported]
  ///
  /// [detach] 为 true 时使用 detached 模式启动（不建立 stdout/stderr 管道），
  /// 用于 Hub 即将退出（关闭 Hub）的场景，避免子进程写管道触发 SIGPIPE。
  Future<EditorLaunchResult> openProject(
    String path, {
    String? projectName,
    bool detach = false,
  }) async {
    if (!supported) {
      return const EditorLaunchResult(EditorLaunchStatus.unsupported);
    }
    if (isRunning(path)) {
      return const EditorLaunchResult(
        EditorLaunchStatus.alreadyRunning,
        '该项目已经在编辑器中打开',
      );
    }

    final name = projectName?.trim().isNotEmpty == true
        ? projectName!.trim()
        : p.basename(path);

    Process process;
    String logPath = '';
    IOSink? sink;
    try {
      final dir = await _logDir();
      final stamp = _stamp(DateTime.now());
      final logFile = File(p.join(dir.path, 'editor-console-$stamp.log'));
      await logFile.create(recursive: true);
      logPath = logFile.path;
      await logFile.writeAsString(
        '# SLIPE Editor 进程日志（Hub 捕获）\n'
        '# 项目：$path\n'
        '# 时间：${DateTime.now().toIso8601String()}\n\n',
      );
      sink = logFile.openWrite(mode: FileMode.append);

      process = await Process.start(
        Platform.resolvedExecutable,
        LaunchArgs.editorArgs(path),
        workingDirectory: Directory(path).existsSync()
            ? path
            : Directory.current.path,
        mode: detach ? ProcessStartMode.detached : ProcessStartMode.normal,
      );
    } catch (e) {
      await sink?.close();
      return EditorLaunchResult(EditorLaunchStatus.failed, '无法启动编辑器进程：$e');
    }

    final entry = _EditorProcess(
      projectPath: path,
      projectName: name,
      process: process,
      startedAt: DateTime.now(),
      logPath: logPath,
      sink: detach ? null : sink,
    );
    _processes[path] = entry;
    CrashLogService.instance.write(
      'INFO',
      '已拉起编辑器进程 pid=${process.pid}：$path'
      '${detach ? '（detached，Hub 即将退出）' : '（日志：$logPath）'}',
    );

    // detached 模式下没有 stdio 管道，也不再有 Hub 负责崩溃上报
    if (detach) return const EditorLaunchResult(EditorLaunchStatus.launched);

    void handleLine(String line) {
      entry.addLine(line);
      try {
        entry.sink?.writeln(line);
      } catch (_) {
        // 输出流已关闭（进程退出竞态），忽略
      }
      final header = RegExp(
        r'\[SLIPE\] role=editor version=(\S+) pid=\d+ log=(.*)',
      );
      final match = header.firstMatch(line);
      if (match != null) {
        entry.editorVersion = match.group(1) ?? '';
        entry.editorLogPath = (match.group(2) ?? '').trim();
      }
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (_) {});
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine, onError: (_) {});

    unawaited(
      process.exitCode.then((code) async {
        try {
          try {
            await entry.sink?.flush();
            await entry.sink?.close();
          } catch (_) {
            // 输出流可能已随进程退出关闭
          }
          entry.sink = null;
          _processes.remove(path);
          // 编辑器全部关闭后恢复 Hub 窗口（Hub 打开项目时可能已隐藏自己）
          if (_processes.isEmpty) {
            try {
              onAllClosed?.call();
            } catch (e) {
              CrashLogService.instance.write('WARN', '恢复 Hub 窗口回调失败：$e');
            }
          }
          final endedAt = DateTime.now();
          CrashLogService.instance.write('INFO', '编辑器进程退出 code=$code：$path');
          if (entry.closing) return;
          if (code == 0) return;
          await _reportCrash(entry, code, endedAt);
        } catch (e, stack) {
          // 崩溃处理本身出错时也要留下痕迹，方便用户手动导出日志
          CrashLogService.instance.fatal(
            e,
            stack,
            source: 'editor-exit-handler',
          );
        }
      }),
    );

    return const EditorLaunchResult(EditorLaunchStatus.launched);
  }

  Future<void> _reportCrash(
    _EditorProcess entry,
    int exitCode,
    DateTime endedAt,
  ) async {
    // 优先使用编辑器自己写的日志（含时间戳与异常堆栈）
    var lines = await CrashLogService.tailOf(entry.editorLogPath, max: 500);
    if (lines.isEmpty) {
      lines = await CrashLogService.tailOf(entry.logPath, max: 500);
    }
    if (lines.isEmpty) lines = List<String>.from(entry.tail);

    final report = EditorCrashReport(
      projectPath: entry.projectPath,
      projectName: entry.projectName,
      exitCode: exitCode,
      startedAt: entry.startedAt,
      endedAt: endedAt,
      logPath: entry.logPath,
      editorLogPath: entry.editorLogPath,
      editorVersion: entry.editorVersion,
      logLines: lines,
    );
    final callback = onCrash;
    if (callback == null) {
      CrashLogService.instance.write(
        'WARN',
        '编辑器异常退出，但 Hub 未注册异常处理回调（exit=$exitCode）',
      );
      return;
    }
    callback(report);
  }

  /// 主动结束所有编辑器进程（仅用于调试 / 退出前清理）
  Future<void> terminateAll() async {
    for (final entry in _processes.values.toList()) {
      entry.closing = true;
      entry.process.kill(ProcessSignal.sigterm);
    }
    _processes.clear();
  }

  Future<Directory> _logDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'logs'));
    await dir.create(recursive: true);
    return dir;
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}

class _EditorProcess {
  _EditorProcess({
    required this.projectPath,
    required this.projectName,
    required this.process,
    required this.startedAt,
    required this.logPath,
    this.sink,
  });

  final String projectPath;
  final String projectName;
  final Process process;
  final DateTime startedAt;
  final String logPath;
  IOSink? sink;

  /// 编辑器自己写的日志路径（由启动头解析）
  String editorLogPath = '';

  /// 编辑器版本（由启动头解析，缺省回退到 Hub 版本）
  String editorVersion = AppInfo.versionLabel;

  /// 主动关闭（不视为崩溃）
  bool closing = false;

  static const int _tailLimit = 500;
  final List<String> tail = [];

  void addLine(String line) {
    tail.add(line);
    if (tail.length > _tailLimit) {
      tail.removeRange(0, tail.length - _tailLimit);
    }
  }
}
