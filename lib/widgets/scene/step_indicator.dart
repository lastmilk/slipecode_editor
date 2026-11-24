import 'package:flutter/material.dart';

import 'scene_palette.dart';
import 'scene_tokens.dart';

/// 三级步骤指示器。
///
/// [currentStep] 从 0 开始；已完成 / 当前 / 未开始三种视觉，
/// 已完成步骤可点击回退。移动端可横向滚动并截断过长标签。
class SceneStepIndicator extends StatelessWidget {
  const SceneStepIndicator({
    super.key,
    required this.currentStep,
    required this.labels,
    this.onStepTap,
    this.accent,
  });

  final int currentStep;
  final List<String> labels;
  final ValueChanged<int>? onStepTap;
  final Color? accent;

  bool _canTap(int index) => onStepTap != null && index < currentStep;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final active = accent ?? Theme.of(context).colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽度 < 600 视为移动端：允许横向滚动，避免步骤文字挤压溢出。
        final compact = constraints.maxWidth < 600;
        final children = <Widget>[];
        for (var i = 0; i < labels.length; i++) {
          if (i > 0) {
            children.add(
              AnimatedContainer(
                duration: SceneTokens.durationFast,
                width: compact ? 20 : 32,
                height: 1,
                margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
                color: i <= currentStep
                    ? active.withValues(alpha: 0.45)
                    : palette.glassBorder,
              ),
            );
          }
          children.add(_buildStep(palette, i, active, compact));
        }

        final row = Row(mainAxisSize: MainAxisSize.min, children: children);
        if (!compact) return row;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: row,
        );
      },
    );
  }

  Widget _buildStep(
    ScenePalette palette,
    int index,
    Color active,
    bool compact,
  ) {
    final done = index < currentStep;
    final current = index == currentStep;
    final labelColor = done
        ? palette.textSecondary
        : (current ? palette.textPrimary : palette.textTertiary);
    final weight = current ? FontWeight.w700 : FontWeight.w500;

    final dot = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? active.withValues(alpha: 0.18)
            : (current ? active.withValues(alpha: 0.14) : Colors.transparent),
        border: Border.all(
          color: done || current
              ? active.withValues(alpha: 0.55)
              : palette.glassBorder,
        ),
        boxShadow: current
            ? [
                BoxShadow(
                  color: active.withValues(alpha: 0.22),
                  blurRadius: 14,
                ),
              ]
            : null,
      ),
      child: done
          ? Icon(Icons.check_rounded, size: 15, color: active)
          : Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: current ? active : palette.textTertiary,
              ),
            ),
    );

    final labelStyle = TextStyle(
      fontSize: 13,
      fontWeight: weight,
      color: labelColor,
    );
    // 移动端限制标签宽度并省略，配合横向滚动避免溢出。
    final label = compact
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 88),
            child: Text(
              labels[index],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          )
        : Text(labels[index], style: labelStyle);

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 8),
          label,
        ],
      ),
    );

    if (!_canTap(index)) {
      return Semantics(
        label: '${labels[index]}，${done ? '已完成' : (current ? '当前步骤' : '未开始')}',
        child: content,
      );
    }
    return Semantics(
      button: true,
      label: '返回第 ${index + 1} 步：${labels[index]}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onStepTap?.call(index),
          child: content,
        ),
      ),
    );
  }
}
