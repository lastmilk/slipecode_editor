import 'dart:io';

import 'package:path/path.dart' as p;

/// 桌面工具安全策略
///
/// 在把「完整命令行」交给 AI 之前做最小必要约束：
/// - 明确拒绝破坏性命令（磁盘 / 关机 / 强推 / 硬重置等）
/// - 文件路径必须位于当前工作区内
/// - 输出统一截断，避免撑爆上下文
class ToolPolicy {
  ToolPolicy._();

  /// 单次工具输出上限（字符）
  static const int maxOutputChars = 24000;

  static final List<({String pattern, String reason})> _denied = [
    (
      pattern: r'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(\/|~)(\s|$)',
      reason: '禁止递归删除根目录 / 主目录',
    ),
    (pattern: r'\bmkfs(\.\w+)?\b', reason: '禁止格式化磁盘'),
    (pattern: r'\bdd\b[^\n]*of=/dev/(sd|nvme|hd|disk)', reason: '禁止直接写块设备'),
    (pattern: r'>\s*/dev/(sd|nvme|hd|disk)', reason: '禁止写块设备'),
    (pattern: r'\b(shutdown|reboot|poweroff|halt)\b', reason: '禁止关机 / 重启系统'),
    (pattern: r':\s*\(\s*\)\s*\{[^}]*:[^}]*\}', reason: '禁止 fork 炸弹'),
    (pattern: r'\bchmod\s+-R\s+(777|a\+rwx)\s+\/(\s|$)', reason: '禁止修改根目录权限'),
    (pattern: r'\bgit\s+push\b[^\n]*--force', reason: '禁止强制推送（会覆盖远端历史）'),
    (
      pattern: r'\bgit\s+clean\s+-[a-zA-Z]*[fdx]',
      reason: '禁止 git clean（可能丢失未跟踪文件）',
    ),
    (pattern: r'\bgit\s+reset\s+--hard', reason: '禁止 git reset --hard（可能丢失改动）'),
    (pattern: r'\bgit\s+checkout\s+--\s+\.', reason: '禁止批量丢弃工作区改动'),
  ];

  /// 命令是否被策略拒绝；返回拒绝原因，允许时返回 null
  static String? validateCommand(String command) {
    final normalized = command.trim();
    if (normalized.isEmpty) return '命令不能为空';
    for (final rule in _denied) {
      if (RegExp(rule.pattern, caseSensitive: false).hasMatch(normalized)) {
        return rule.reason;
      }
    }
    return null;
  }

  /// 目标路径是否位于工作区内（含根目录本身）
  static bool insideWorkspace(String root, String target) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedTarget = p.normalize(p.absolute(target));
    if (normalizedTarget == normalizedRoot) return true;
    return p.isWithin(normalizedRoot, normalizedTarget);
  }

  /// 解析并校验用户传入的相对路径
  static String? resolveInside(String root, String? relativeOrAbsolute) {
    final value = (relativeOrAbsolute ?? '').trim();
    final target = value.isEmpty ? root : p.join(root, value);
    if (!insideWorkspace(root, target)) return null;
    return target;
  }

  /// 截断长输出（保留头部与尾部，提示省略量）
  static String truncate(String text, [int max = maxOutputChars]) {
    if (text.length <= max) return text;
    final head = text.substring(0, max ~/ 2);
    final tail = text.substring(text.length - max ~/ 2);
    final omitted = text.length - head.length - tail.length;
    return '$head\n…（已省略 $omitted 字符）…\n$tail';
  }

  /// 检查可执行文件是否存在于 PATH
  static bool hasExecutable(String name, {String? pathValue}) {
    final value = pathValue ?? Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final candidates = Platform.isWindows
        ? [name, '$name.exe', '$name.bat', '$name.cmd']
        : [name];
    for (final dir in value.split(separator)) {
      if (dir.trim().isEmpty) continue;
      for (final candidate in candidates) {
        if (File(p.join(dir, candidate)).existsSync()) return true;
      }
    }
    return false;
  }
}
