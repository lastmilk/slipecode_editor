import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_globals.dart';
import 'crash_log_service.dart';
import 'desktop_prefs_service.dart';

/// 内存阈值（字节）
class MemoryThresholds {
  const MemoryThresholds({required this.warnBytes, required this.exitBytes});

  final int warnBytes;
  final int exitBytes;

  /// 按物理内存百分比换算阈值；退出阈值始终高于提醒阈值
  factory MemoryThresholds.from({
    required int totalBytes,
    required int warnPercent,
    required int exitPercent,
  }) {
    final total = totalBytes <= 0 ? 0 : totalBytes;
    final warn = warnPercent.clamp(10, 95);
    final exit = exitPercent.clamp(warn + 1, 100);
    return MemoryThresholds(
      warnBytes: total * warn ~/ 100,
      exitBytes: total * exit ~/ 100,
    );
  }
}

class _MemorySnapshot {
  const _MemorySnapshot({
    required this.totalBytes,
    required this.availableBytes,
    required this.rssBytes,
  });

  final int totalBytes;
  final int availableBytes;
  final int rssBytes;
}

/// Linux 保守内存策略
///
/// Linux 下内存占用过高容易被 OOM Killer 直接杀死（来不及保存），
/// 因此在接近物理内存上限时主动降载、提示，超过硬阈值则保存状态后退出，
/// 交由 systemd / supervisor 重新拉起。
class MemoryGuardService {
  MemoryGuardService._();

  static final MemoryGuardService instance = MemoryGuardService._();

  Timer? _timer;
  bool _started = false;
  bool _exiting = false;
  DateTime? _lastWarnAt;

  bool get isRunning => _timer != null;

  /// 启动守护（仅 Linux 生效，阈值来自本机偏好）
  Future<void> start({
    required Future<void> Function() saveState,
  }) async {
    if (_started || !Platform.isLinux) return;
    _started = true;

    final prefs = DesktopPrefsService.instance;
    if (!prefs.linuxMemoryGuardEnabled) return;

    // 保守内存分配：收紧图片缓存上限，减少不可控的峰值
    try {
      PaintingBinding.instance.imageCache.maximumSize = 200;
      PaintingBinding.instance.imageCache.maximumSizeBytes = 96 * 1024 * 1024;
    } catch (_) {}

    _timer = Timer.periodic(
      Duration(seconds: prefs.linuxMemoryCheckSeconds),
      (_) => unawaited(_check(saveState)),
    );
  }

  Future<void> _check(Future<void> Function() saveState) async {
    final prefs = DesktopPrefsService.instance;
    if (_exiting || !prefs.linuxMemoryGuardEnabled) return;

    final snapshot = await _readSnapshot();
    if (snapshot == null || snapshot.totalBytes <= 0) return;

    final thresholds = MemoryThresholds.from(
      totalBytes: snapshot.totalBytes,
      warnPercent: prefs.linuxMemoryWarnPercent,
      exitPercent: prefs.linuxMemoryExitPercent,
    );

    // 退出策略只以本进程 RSS 为准：系统 MemAvailable 受页缓存与其它程序影响，
    // 用它触发退出会误杀正常进程。
    if (snapshot.rssBytes >= thresholds.exitBytes) {
      await _saveAndExit(saveState, snapshot, thresholds);
      return;
    }

    if (snapshot.rssBytes >= thresholds.warnBytes) {
      _releaseCaches();
      _notifyLowMemory(snapshot, thresholds);
    }
  }

  void _releaseCaches() {
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    } catch (_) {}
  }

  void _notifyLowMemory(_MemorySnapshot snapshot, MemoryThresholds thresholds) {
    final now = DateTime.now();
    final last = _lastWarnAt;
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _lastWarnAt = now;
    debugPrint(
      '内存偏高：RSS ${_mb(snapshot.rssBytes)}MB / 提醒阈值 '
      '${_mb(thresholds.warnBytes)}MB，已清理图片缓存',
    );
    CrashLogService.instance.write(
      'WARN',
      'Linux 内存偏高：RSS=${snapshot.rssBytes} 阈值=${thresholds.warnBytes}',
    );
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('内存占用偏高，已清理缓存；可在偏好设置中调整 Linux 内存策略'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _saveAndExit(
    Future<void> Function() saveState,
    _MemorySnapshot snapshot,
    MemoryThresholds thresholds,
  ) async {
    _exiting = true;
    _timer?.cancel();
    _timer = null;
    CrashLogService.instance.write(
      'FATAL',
      'Linux 内存超过退出阈值：RSS=${snapshot.rssBytes} '
      '阈值=${thresholds.exitBytes}，保存状态后退出',
    );
    try {
      await saveState().timeout(const Duration(seconds: 3));
    } catch (e) {
      CrashLogService.instance.write('ERROR', '退出前保存状态失败：$e');
    }
    try {
      await DesktopPrefsService.instance.save();
    } catch (_) {}
    // 退出码 0：由 systemd / supervisor 的 Restart=always 重新拉起
    exit(0);
  }

  Future<_MemorySnapshot?> _readSnapshot() async {
    try {
      final meminfo = await File('/proc/meminfo').readAsLines();
      int? totalKb;
      int? availableKb;
      for (final line in meminfo) {
        if (line.startsWith('MemTotal:')) {
          totalKb = _kb(line);
        } else if (line.startsWith('MemAvailable:')) {
          availableKb = _kb(line);
        }
      }
      if (totalKb == null || availableKb == null) return null;

      int rssBytes;
      final rss = await _readVmRssKb();
      if (rss != null) {
        rssBytes = rss * 1024;
      } else {
        rssBytes = ProcessInfo.currentRss;
      }
      return _MemorySnapshot(
        totalBytes: totalKb * 1024,
        availableBytes: availableKb * 1024,
        rssBytes: rssBytes,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int?> _readVmRssKb() async {
    try {
      final status = await File('/proc/self/status').readAsLines();
      for (final line in status) {
        if (line.startsWith('VmRSS:')) return _kb(line);
      }
    } catch (_) {}
    return null;
  }

  /// 解析 `MemTotal:       16384000 kB` 的数值（kB）
  int? _kb(String line) {
    final match = RegExp(r'(\d+)').firstMatch(line);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  int _mb(int bytes) => bytes ~/ (1024 * 1024);
}
