import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'app_globals.dart';

/// AI 一次待审批的文件改动
class AiChangeProposal {
  /// 操作类型：写入 / 新建 / 替换 / 重命名 / 删除
  final String action;

  /// 目标文件（相对或绝对路径）
  final String path;

  /// 修改前的文本（新建时为空）
  final String? before;

  /// 修改后的文本（删除时为空）
  final String? after;

  const AiChangeProposal({
    required this.action,
    required this.path,
    this.before,
    this.after,
  });
}

/// AI 改动审批服务
///
/// AI 通过 MCP 工具产生的所有落盘操作都必须先经过用户审批；
/// 用户拒绝时返回 false，工具不写文件。
class AiApprovalService {
  AiApprovalService._();

  static final AiApprovalService instance = AiApprovalService._();

  bool _allowAllForSession = false;

  /// 重置「本次会话全部允许」
  void resetSessionAllowance() => _allowAllForSession = false;

  /// 请求审批；没有可用导航上下文时默认拒绝（安全优先）
  Future<bool> request(AiChangeProposal proposal) async {
    if (_allowAllForSession) return true;
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return false;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _ApprovalDialog(proposal: proposal),
    );
    if (result == 'all') {
      _allowAllForSession = true;
      return true;
    }
    return result == 'approve';
  }
}

class _ApprovalDialog extends StatelessWidget {
  const _ApprovalDialog({required this.proposal});

  final AiChangeProposal proposal;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final preview = _buildPreview();
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(t('approval.title'))),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${proposal.action}  ${proposal.path}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1B1B1D) : const Color(0xFFF6F8FA),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
              child: SingleChildScrollView(
                child: Text(
                  preview,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t('approval.hint'),
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('reject'),
          child: Text(t('approval.reject')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('all'),
          child: Text(t('approval.allowAll')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop('approve'),
          child: Text(t('approval.approve')),
        ),
      ],
    );
  }

  String _buildPreview() {
    if (proposal.action == t('approval.rename') || proposal.action == t('approval.delete')) {
      return '${proposal.before ?? ''}\n${proposal.after ?? ''}'.trim();
    }
    if (proposal.before == null || proposal.before!.isEmpty) {
      return _truncate(proposal.after ?? '');
    }
    if (proposal.after == null) {
      return '- ${proposal.before}';
    }
    // 替换：展示删除行与新增行，便于用户快速判断
    final removed = proposal.before!
        .split('\n')
        .where((line) => !proposal.after!.contains(line))
        .take(40)
        .map((line) => '- $line')
        .join('\n');
    final added = proposal.after!
        .split('\n')
        .where((line) => !proposal.before!.contains(line))
        .take(40)
        .map((line) => '+ $line')
        .join('\n');
    if (removed.isEmpty && added.isEmpty) return _truncate(proposal.after!);
    return '$removed\n$added'.trim();
  }

  String _truncate(String text) {
    const maxLines = 60;
    final lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    return '${lines.take(maxLines).join('\n')}\n…（共 ${lines.length} 行）';
  }
}
