import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../agent/mcp_tools.dart';

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
