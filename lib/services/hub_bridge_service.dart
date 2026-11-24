import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'crash_log_service.dart';
import 'desktop_platform.dart';
import 'launch_args.dart';

/// Hub / Editor 跨进程控制桥
///
/// Hub 打开项目后可能隐藏自己（进程保留），Editor 返回 Hub 时需要把
/// 隐藏的 Hub 窗口叫回前台。Hub 在启动时监听一个本机回环端口，并把
/// `{pid, port, token}` 写入应用支持目录；Editor 读取该文件后连接并发起
/// `show` 请求。Hub 不存在时，Editor 直接拉起一个新的 Hub 进程。
class HubBridgeService {
  HubBridgeService._();

  static final HubBridgeService instance = HubBridgeService._();

  static const _endpointFileName = 'hub_endpoint.json';
  static const _connectTimeout = Duration(milliseconds: 400);

  ServerSocket? _server;
  String _token = '';
  File? _endpointFile;

  bool get isListening => _server != null;

  /// Hub 角色：开始监听 Editor 的「显示窗口」请求
  Future<void> startHubListener({
    required Future<void> Function() onShow,
  }) async {
    if (!DesktopPlatform.isDesktop || !LaunchArgs.isHub) return;
    if (_server != null) return;
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _token = _randomToken();
      final file = await _endpointFileHandle();
      _endpointFile = file;
      await file.writeAsString(
        jsonEncode({
          'pid': pid,
          'port': server.port,
          'token': _token,
        }),
        flush: true,
      );
      server.listen((socket) => _handleClient(socket, onShow), onError: (_) {});
      CrashLogService.instance.write(
        'INFO',
        'Hub 控制桥已监听 127.0.0.1:${server.port}',
      );
    } catch (e) {
      // 控制桥不可用时不影响 Hub 本身
      debugPrint('Hub 控制桥启动失败：$e');
      CrashLogService.instance.write('WARN', 'Hub 控制桥启动失败：$e');
    }
  }

  /// Hub 角色：退出前停止监听并清理端点文件
  Future<void> stopHubListener() async {
    final server = _server;
    _server = null;
    try {
      await server?.close();
    } catch (_) {}
    final file = _endpointFile;
    _endpointFile = null;
    try {
      if (file != null && await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map && raw['pid'] == pid) await file.delete();
      }
    } catch (_) {}
  }

  /// Editor 角色：请求 Hub 显示窗口；Hub 不在线返回 false
  Future<bool> requestShow() async {
    if (!DesktopPlatform.isDesktop) return false;
    Socket? socket;
    try {
      final file = await _endpointFileHandle();
      if (!await file.exists()) return false;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return false;
      final port = (raw['port'] as num?)?.toInt() ?? 0;
      final hubPid = (raw['pid'] as num?)?.toInt() ?? 0;
      final token = raw['token'] as String? ?? '';
      if (port <= 0 || token.isEmpty) return false;
      if (hubPid > 0 && !_pidAlive(hubPid)) return false;

      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _connectTimeout,
      );
      socket.writeln('$token show');
      await socket.flush();
      final reply = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_connectTimeout);
      return reply.trim() == 'ok';
    } catch (e) {
      debugPrint('唤醒 Hub 失败：$e');
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// Editor 角色：显示已存在的 Hub；失败时拉起新的 Hub 进程
  Future<bool> showOrLaunchHub() async {
    if (!DesktopPlatform.isDesktop) return false;
    if (await requestShow()) return true;
    try {
      await Process.start(
        Platform.resolvedExecutable,
        LaunchArgs.hubArgs(),
        mode: ProcessStartMode.detached,
      );
      CrashLogService.instance.write('INFO', 'Editor 返回 Hub：已拉起新的 Hub 进程');
      return true;
    } catch (e) {
      CrashLogService.instance.write('ERROR', '拉起 Hub 进程失败：$e');
      return false;
    }
  }

  Future<void> _handleClient(
    Socket socket,
    Future<void> Function() onShow,
  ) async {
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_connectTimeout);
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2 || parts[0] != _token || parts[1] != 'show') {
        socket.writeln('denied');
        await socket.flush();
        return;
      }
      socket.writeln('ok');
      await socket.flush();
      await onShow();
    } catch (e) {
      debugPrint('Hub 控制桥请求处理失败：$e');
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<File> _endpointFileHandle() async {
    final existing = _endpointFile;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _endpointFileName));
  }

  /// 进程是否存活（Linux 用 /proc，其余平台直接信任端点文件）
  bool _pidAlive(int targetPid) {
    if (!Platform.isLinux) return true;
    return Directory('/proc/$targetPid').existsSync();
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
