import 'package:flutter/material.dart';

import 'practice_catalog.dart';
import 'practice_controller.dart';
import '../services/practice_service.dart';

/// 应用内「教学模式」悬浮球（不调用系统悬浮窗）
class PracticeFloatingBall extends StatelessWidget {
  const PracticeFloatingBall({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = PracticeController.instance;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final result = controller.result;
        final passed = result?.passed ?? false;
        final color = passed
            ? const Color(0xFF00A870)
            : result == null
            ? const Color(0xFF2D6CF6)
            : const Color(0xFFFF8B00);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              right: 16,
              bottom: 132,
              child: GestureDetector(
                onTap: () => _openSheet(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Icon(
                        passed
                            ? Icons.check_rounded
                            : result == null
                            ? Icons.school_outlined
                            : Icons.priority_high_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.66),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '教学模式',
                        style: TextStyle(fontSize: 9, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const PracticeSheet(),
    );
  }
}

/// 教学模式面板：检查 / 提示 / 参考答案 / 退出
class PracticeSheet extends StatefulWidget {
  const PracticeSheet({super.key});

  @override
  State<PracticeSheet> createState() => _PracticeSheetState();
}

class _PracticeSheetState extends State<PracticeSheet> {
  bool _showHints = false;
  bool _showAnswer = false;

  @override
  Widget build(BuildContext context) {
    final controller = PracticeController.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final spec = controller.spec;
    if (spec == null) {
      return const SizedBox.shrink();
    }
    final height = MediaQuery.of(context).size.height;
    return Container(
      height: height * 0.78,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1B1D) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black26,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.school_rounded,
                  size: 20,
                  color: Color(0xFF2D6CF6),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spec.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final current = controller.result;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    _statusCard(current, isDark),
                    const SizedBox(height: 14),
                    const Text(
                      '需求',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      spec.requirement,
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: controller.checking
                                ? null
                                : () => controller.check(),
                            icon: controller.checking
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.fact_check_outlined,
                                    size: 16,
                                  ),
                            label: const Text('提交检查'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () =>
                              setState(() => _showHints = !_showHints),
                          child: Text(_showHints ? '收起提示' : '查看提示'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _showAnswer = !_showAnswer),
                      icon: const Icon(Icons.menu_book_outlined, size: 16),
                      label: Text(_showAnswer ? '收起参考答案' : '查看参考答案'),
                    ),
                    if (_showHints) ...[
                      const SizedBox(height: 12),
                      _hintList(spec, isDark),
                    ],
                    if (_showAnswer) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SelectableText(
                          spec.answer,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.5,
                            color: Color(0xFFE6EDF3),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await controller.exit();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text('退出教学模式'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '练习项目保存在应用私有目录，退出教学模式不会删除代码。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white30 : Colors.black38,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(PracticeCheckResult? result, bool isDark) {
    final passed = result?.passed == true;
    final issues = result?.issues ?? const <String>[];
    final color = result == null
        ? const Color(0xFF2D6CF6)
        : passed
        ? const Color(0xFF00A870)
        : const Color(0xFFFF8B00);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result == null
                    ? Icons.tips_and_updates_outlined
                    : passed
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                result == null
                    ? '执行检查后可查看结果'
                    : passed
                    ? '检测通过'
                    : '还需要继续完善',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '· $issue',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _hintList(PracticeSpec spec, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF26262B) : const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < spec.hints.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${i + 1}. ${spec.hints[i]}',
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
