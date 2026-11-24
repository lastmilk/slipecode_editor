import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_info.dart';

/// 进程级日志 / 崩溃记录
///
/// 每个进程（Hub / Editor）都会在自己的日志文件里记录启动信息、
/// [debugPrint] 输出与致命异常。Hub 拉起 Editor 时也会捕获子进程输出，
/// 因此即使编辑器进程直接崩溃（segfault 等），也能拿到最后一段日志。
class CrashLogService {
  CrashLogService._();

  static final CrashLogService instance = CrashLogService._();

  /// 单个日志文件允许写入的最大行数（避免 LSP 流量把文件写爆）
  static const int _maxLines = 30000;

  File? _file;
  String _role = 'hub';
  int _lines = 0;
  bool _initialized = false;
  bool _teeInstalled = false;

  /// 待写盘内容：合并高频日志，避免每条 debugPrint 都同步写文件
  final StringBuffer _pendingWrites = StringBuffer();
  Timer? _flushTimer;

  String get role => _role;

  /// 日志文件路径（初始化失败时为空串）
  String get path => _file?.path ?? '';

  bool get isReady => _file != null;

  /// 初始化：创建日志文件、写入启动信息，并把 debugPrint 同步到文件
  Future<void> init({
    required String role,
    Map<String, String> extra = const {},
  }) async {
    if (_initialized) return;
    _initialized = true;
    _role = role;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'logs'));
      await dir.create(recursive: true);
      final stamp = _stamp(DateTime.now());
      _file = File(p.join(dir.path, '$role-$stamp.log'));
      await _file!.create(recursive: true);

      write('INFO', '启动 $role 进程 · ${AppInfo.versionLabel} · pid=$pid');
      write('INFO', '系统：${AppInfo.osLabel}');
      for (final entry in extra.entries) {
        write('INFO', '${entry.key}：${entry.value}');
      }
      write('INFO', '日志文件：${_file!.path}');

      // 机器可读的启动头：Hub 依赖它识别编辑器版本与日志路径
      // 注意：用 stderr 输出，exit() 时不会丢失（stdout 是带缓冲的）
      stderr.writeln(
        '[SLIPE] role=$role version=${AppInfo.versionLabel} pid=$pid log=${_file!.path}',
      );
      // 启动信息立即落盘，后续日志再走批量写入
      _flush();
      _installTee();
    } catch (e) {
      // 日志能力不可用时不影响主流程
      stderr.writeln('[SLIPE] 初始化日志失败：$e');
    }
  }

  /// 关闭 debugPrint 输出（编辑器开始渲染后再开启，避免把首帧日志刷爆）
  void _installTee() {
    if (_teeInstalled) return;
    _teeInstalled = true;
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        // LSP 的 JSON-RPC 流量既长又多，默认不写进崩溃日志
        if (!message.contains('jsonrpc')) {
          write('DEBUG', message);
        }
      }
      previous(message, wrapWidth: wrapWidth);
    };
  }

  /// 写一行日志（先入缓冲，200ms 内批量落盘）
  void write(String level, String message) {
    if (_lines >= _maxLines) return;
    _lines++;
    final line = '${DateTime.now().toIso8601String()} [$level] $message';
    if (_file != null) {
      _pendingWrites.write('$line\n');
      _flushTimer ??= Timer(const Duration(milliseconds: 200), _flush);
    }
    // 同时输出到控制台：Hub 侧的子进程捕获也能收到（stderr 不会因 exit 丢缓冲）
    stderr.writeln(line);
  }

  /// 把缓冲内容一次性写盘
  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _file;
    if (file == null || _pendingWrites.isEmpty) return;
    final text = _pendingWrites.toString();
    _pendingWrites.clear();
    try {
      file.writeAsStringSync(text, mode: FileMode.append);
    } catch (_) {
      // 忽略写盘失败
    }
  }

  /// 记录致命异常（立即 flush，随后进程会退出）
  void fatal(Object error, StackTrace? stack, {String source = 'uncaught'}) {
    _flush();
    final buffer = StringBuffer()
      ..writeln('${DateTime.now().toIso8601String()} [FATAL] ($source) $error');
    if (stack != null) buffer.writeln(stack.toString());
    final text = buffer.toString();
    final file = _file;
    if (file != null) {
      try {
        file.writeAsStringSync(text, mode: FileMode.append, flush: true);
      } catch (_) {}
    }
    stderr.writeln(text);
  }

  /// 读取日志尾部（供异常窗口展示）
  Future<List<String>> tail({int max = 400}) async {
    final file = _file;
    if (file == null || !await file.exists()) return const [];
    try {
      final lines = await file.readAsLines();
      if (lines.length <= max) return lines;
      return lines.sublist(lines.length - max);
    } catch (_) {
      return const [];
    }
  }

  /// 从任意日志文件读取尾部
  static Future<List<String>> tailOf(String path, {int max = 400}) async {
    if (path.isEmpty) return const [];
    try {
      final file = File(path);
      if (!await file.exists()) return const [];
      final lines = await file.readAsLines();
      if (lines.length <= max) return lines;
      return lines.sublist(lines.length - max);
    } catch (_) {
      return const [];
    }
  }

  /// 读取文本文件内容（限制大小）
  static Future<String> readText(
    String path, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    if (path.isEmpty) return '';
    try {
      final file = File(path);
      if (!await file.exists()) return '';
      final size = await file.length();
      if (size <= maxBytes) return await file.readAsString();
      final bytes = await file
          .openRead(size - maxBytes)
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}
