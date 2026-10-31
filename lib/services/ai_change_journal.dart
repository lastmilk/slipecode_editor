import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// AI 一次落盘改动的类型
enum AiChangeKind { write, create, delete, rename }

/// 一条 AI 改动记录
///
/// AI 修改默认直接保存，此记录用于：
/// 1. 在对话流/退出时展示待确认改动
/// 2. 用户拒绝时按 [before] 回滚
/// 3. 阻止未确认的文件被推送到 GitHub / Gitee
class AiChangeEntry {
  final String id;
  final AiChangeKind kind;

  /// 展示用动作名（已本地化）
  final String action;

  /// 原始绝对路径
  final String path;

  /// 重命名后的绝对路径（仅 rename 使用）
  final String? newPath;

  /// 修改前的内容；null 表示文件原本不存在
  final String? before;

  /// 修改后的内容；null 表示文件被删除
  final String? after;

  /// 用户是否已确认保留该改动
  bool approved;

  final DateTime createdAt;

  AiChangeEntry({
    required this.id,
    required this.kind,
    required this.action,
    required this.path,
    this.newPath,
    this.before,
    this.after,
    this.approved = false,
    required this.createdAt,
  });

  bool get reversible => kind != AiChangeKind.delete || before != null;
}

/// AI 改动台账（全局单例）
///
/// 取代原先的「每次改动弹窗审批」：改动直接落盘并登记，
/// 用户在对话流或退出时选择保留 / 撤回。
class AiChangeJournal extends ChangeNotifier {
  AiChangeJournal._();

  static final AiChangeJournal instance = AiChangeJournal._();

  final List<AiChangeEntry> _entries = [];
  int _seq = 0;

  List<AiChangeEntry> get entries => List.unmodifiable(_entries);

  /// 尚未确认的改动
  List<AiChangeEntry> get pending =>
      _entries.where((entry) => !entry.approved).toList();

  int get pendingCount => pending.length;
  bool get hasPending => pendingCount > 0;

  /// 某绝对路径是否存在未确认的 AI 改动（用于阻止推送）
  bool isBlocked(String absolutePath) {
    final target = p.normalize(absolutePath);
    for (final entry in pending) {
      if (p.normalize(entry.path) == target) return true;
      final newPath = entry.newPath;
      if (newPath != null && p.normalize(newPath) == target) return true;
    }
    return false;
  }

  /// 登记一次改动
  ///
  /// 同一文件在本次会话内的连续修改会合并为一条，保留最初的 before，
  /// 这样「撤回」可以回到 AI 动手前的原始内容。
  void record({
    required AiChangeKind kind,
    required String action,
    required String path,
    String? newPath,
    String? before,
    String? after,
  }) {
    if (kind != AiChangeKind.rename) {
      final index = _entries.indexWhere((entry) =>
          entry.kind != AiChangeKind.rename &&
          p.normalize(entry.path) == p.normalize(path));
      if (index >= 0) {
        final old = _entries[index];
        _entries[index] = AiChangeEntry(
          id: old.id,
          kind: kind,
          action: action,
          path: path,
          before: old.before,
          after: after,
          approved: false,
          createdAt: old.createdAt,
        );
        notifyListeners();
        return;
      }
    }
    _entries.add(
      AiChangeEntry(
        id: 'ai-change-${++_seq}',
        kind: kind,
        action: action,
        path: path,
        newPath: newPath,
        before: before,
        after: after,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  /// 确认保留全部改动
  void approveAll() {
    if (_entries.isEmpty) return;
    for (final entry in _entries) {
      entry.approved = true;
    }
    notifyListeners();
  }

  /// 确认保留单条改动
  void approve(AiChangeEntry entry) {
    entry.approved = true;
    notifyListeners();
  }

  /// 撤回单条改动（恢复文件到 AI 修改前）
  Future<bool> revert(AiChangeEntry entry) async {
    try {
      switch (entry.kind) {
        case AiChangeKind.rename:
          final oldPath = entry.path;
          final newPath = entry.newPath;
          if (newPath == null) return false;
          if (File(newPath).existsSync()) {
            await File(newPath).parent.create(recursive: true);
            await File(newPath).rename(oldPath);
          } else if (Directory(newPath).existsSync()) {
            await Directory(newPath).parent.create(recursive: true);
            await Directory(newPath).rename(oldPath);
          }
        case AiChangeKind.create:
          final file = File(entry.path);
          if (await file.exists()) await file.delete();
        case AiChangeKind.delete:
          final before = entry.before;
          if (before == null) return false; // 目录无法自动恢复
          final file = File(entry.path);
          await file.parent.create(recursive: true);
          await file.writeAsString(before);
        case AiChangeKind.write:
          final before = entry.before ?? '';
          final file = File(entry.path);
          await file.parent.create(recursive: true);
          await file.writeAsString(before);
      }
      _entries.remove(entry);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('撤回 AI 改动失败：$e');
      return false;
    }
  }

  /// 撤回全部未确认改动；返回成功撤回的条数
  Future<int> revertAllPending() async {
    var count = 0;
    for (final entry in pending.toList()) {
      if (await revert(entry)) count++;
    }
    notifyListeners();
    return count;
  }

  /// 清理已确认的记录
  void clearApproved() {
    _entries.removeWhere((entry) => entry.approved);
    notifyListeners();
  }

  /// 清空全部记录（不恢复文件）
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
