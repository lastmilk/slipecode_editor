import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../agent/mcp_tools.dart';
import '../services/agent_permission_service.dart';

/// AI 任务阶段 TODO 面板
class AiTodoPanel extends StatelessWidget {
  const AiTodoPanel({super.key, required this.todos, required this.isDark});

  final List<AgentTodoItem> todos;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final done = todos.where((t) => t.completed).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232326) : const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE2E5E9),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist_rounded,
                  size: 15, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Text(
                '任务进度 $done/${todos.length}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in todos)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            item.completed
                                ? Icons.check_circle_rounded
                                : item.inProgress
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_unchecked_rounded,
                            size: 14,
                            color: item.completed
                                ? Colors.green
                                : item.inProgress
                                    ? Colors.blueAccent
                                    : (isDark
                                        ? Colors.white38
                                        : Colors.black38),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.content,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: item.completed
                                    ? (isDark ? Colors.white38 : Colors.black45)
                                    : (isDark ? Colors.white : Colors.black87),
                                decoration: item.completed
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// AI 向用户提问的卡片
class AiQuestionCard extends StatefulWidget {
  const AiQuestionCard({
    super.key,
    required this.question,
    required this.isDark,
    required this.onSubmit,
    required this.onCancel,
  });

  final Map<String, dynamic> question;
  final bool isDark;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<AiQuestionCard> createState() => _AiQuestionCardState();
}

class _AiQuestionCardState extends State<AiQuestionCard> {
  final TextEditingController _controller = TextEditingController();
  String? _choice;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = (widget.question['question'] ?? '').toString();
    final options = (widget.question['options'] as List?)?.cast<String>() ??
        const <String>[];
    final allowCustom = widget.question['allowCustom'] != false;
    final canSubmit = _choice != null || _controller.text.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            widget.isDark ? const Color(0xFF1F2A3D) : const Color(0xFFEFF5FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline_rounded,
                  size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              const Text(
                'AI 需要你确认',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onCancel,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.redAccent,
                ),
                child: const Text('中断', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            question,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final option in options)
                  ChoiceChip(
                    label: Text(option, style: const TextStyle(fontSize: 12)),
                    selected: _choice == option,
                    onSelected: (_) => setState(() => _choice = option),
                  ),
              ],
            ),
          ],
          if (allowCustom) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: options.isEmpty ? '输入你的回答…' : '或补充说明…',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: canSubmit
                  ? () => widget.onSubmit(
                        _choice ?? _controller.text.trim(),
                      )
                  : null,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('提交回答', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Agent 危险操作审批卡片
///
/// 对应安全设置里的「手动审批 / 自动审批 / 自定义」：当 Agent 要执行
/// 命令、修改文件或访问网络时，在此由用户决定是否放行。
class AiApprovalCard extends StatelessWidget {
  const AiApprovalCard({
    super.key,
    required this.request,
    required this.isDark,
    required this.onResolve,
  });

  final AgentPermissionRequest request;
  final bool isDark;

  /// (是否允许, 是否本会话总是允许/拒绝)
  final void Function(bool approved, {bool always}) onResolve;

  @override
  Widget build(BuildContext context) {
    final color = request.risk == AgentRiskLevel.critical
        ? Colors.redAccent
        : Colors.orangeAccent;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232326) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: color),
              const SizedBox(width: 6),
              const Text(
                '需要你的授权',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  request.risk.label,
                  style: TextStyle(fontSize: 9.5, color: color),
                ),
              ),
              const Spacer(),
              Text(
                request.tool,
                style: TextStyle(
                  fontSize: 9.5,
                  fontFamily: 'monospace',
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            request.title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B1B1D) : const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                request.detail,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  fontFamily: 'monospace',
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onResolve(false),
                  child: const Text('拒绝', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              if (request.allowAlways)
                Expanded(
                  child: TextButton(
                    onPressed: () => onResolve(true, always: true),
                    child: const Text(
                      '本会话总是允许',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => onResolve(true),
                  child: const Text('允许', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 全局审批对话框：当聊天面板不可见时使用，避免用户看不到审批卡片。
Future<({bool approved, bool always})?> showAiApprovalDialog(
  BuildContext context,
  AgentPermissionRequest request,
) {
  return showDialog<({bool approved, bool always})>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final color = request.risk == AgentRiskLevel.critical
          ? Colors.redAccent
          : Colors.orangeAccent;
      return AlertDialog(
        title: Row(
          children: [
            Icon(Icons.shield_outlined, size: 18, color: color),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Agent 请求授权', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    request.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${request.risk.label} · ${request.tool}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1B1B1D) : const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    request.detail,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop((approved: false, always: false)),
            child: const Text('拒绝'),
          ),
          if (request.allowAlways)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop((approved: true, always: true)),
              child: const Text('本会话总是允许'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop((approved: true, always: false)),
            child: const Text('允许'),
          ),
        ],
      );
    },
  );
}

/// 计划确认卡片（/plan 模式）
class AiPlanConfirmCard extends StatelessWidget {
  const AiPlanConfirmCard({
    super.key,
    required this.plan,
    required this.isDark,
    required this.onResolve,
  });

  final Map<String, dynamic> plan;
  final bool isDark;
  final ValueChanged<bool> onResolve;

  @override
  Widget build(BuildContext context) {
    final title = (plan['title'] ?? '实施计划').toString();
    final markdown = (plan['markdown'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232326) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.assignment_outlined,
                  size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              const Text(
                '计划已生成',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '已保存到 .slipe/plans',
                style: TextStyle(
                  fontSize: 9,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: markdown,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                  h1: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                  h2: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                  h3: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  listBullet: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onResolve(false),
                  child: const Text('暂不执行', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => onResolve(true),
                  child: const Text('执行计划', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
