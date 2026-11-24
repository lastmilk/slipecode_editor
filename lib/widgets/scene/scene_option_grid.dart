import 'package:flutter/material.dart';

import '../../models/scene.dart';
import 'glass_card.dart';
import 'scene_palette.dart';
import 'scene_tokens.dart';

/// 二级/三级选项网格：移动端单列、平板双列、桌面三列，高度不足时可滚动。
class SceneOptionGrid extends StatelessWidget {
  const SceneOptionGrid({super.key, required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = MediaQuery.sizeOf(context).width;
        final maxColumns = width >= 1100 ? 3 : (width >= 700 ? 2 : 1);
        // 选项较少时收敛列数，避免出现大片留白（如只有两个范式）。
        final columns = cards.length < maxColumns ? cards.length : maxColumns;
        final safeColumns = columns <= 0 ? 1 : columns;
        const spacing = SceneTokens.gap;
        final rows = (cards.length + safeColumns - 1) ~/ safeColumns;
        final double extent;
        if (safeColumns == 1) {
          // 单列时保证卡片内容（图标 + 标题 + 三行描述）不溢出。
          extent = 180;
        } else if (constraints.maxHeight.isFinite && rows > 0) {
          extent = ((constraints.maxHeight - (rows - 1) * spacing) / rows)
              .clamp(178.0, 220.0)
              .toDouble();
        } else {
          extent = 172;
        }
        return SingleChildScrollView(
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: cards.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: safeColumns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
              mainAxisExtent: extent,
            ),
            itemBuilder: (context, index) => cards[index],
          ),
        );
      },
    );
  }
}

/// 选中态外壳：accent 2px 描边（未选中时保留透明占位，避免布局跳动）。
class SelectableShell extends StatelessWidget {
  const SelectableShell({
    super.key,
    required this.selected,
    required this.accent,
    required this.child,
  });

  final bool selected;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: SceneTokens.durationFast,
      curve: SceneTokens.curve,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SceneTokens.radiusMedium + 2),
        border: Border.all(
          color: selected ? accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
    );
  }
}

/// 右上角选择圆点：选中为实心对勾。
class SelectDot extends StatelessWidget {
  const SelectDot({super.key, required this.selected, required this.accent});

  final bool selected;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return AnimatedContainer(
      duration: SceneTokens.durationFast,
      curve: SceneTokens.curve,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? accent : palette.glassFill,
        border: Border.all(
          color: selected ? accent : palette.glassBorder,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 15, color: palette.bgTop)
          : null,
    );
  }
}

/// 细分元素（产出形态）卡片。
class SceneElementCard extends StatelessWidget {
  const SceneElementCard({
    super.key,
    required this.scene,
    required this.element,
    required this.selected,
    required this.onTap,
  });

  final SceneDefinition scene;
  final SceneElement element;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return SelectableShell(
      selected: selected,
      accent: scene.accent,
      child: GlassCard(
        onTap: onTap,
        accent: scene.accent,
        radius: SceneTokens.radiusMedium,
        padding: EdgeInsets.zero,
        semanticLabel: '选择细分元素 ${element.name}',
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: scene.accent.withValues(alpha: 0.12),
                      border: Border.all(
                        color: scene.accent.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Icon(
                      element.icon,
                      size: 20,
                      color: scene.accent,
                    ),
                  ),
                  const Spacer(),
                  SelectDot(selected: selected, accent: scene.accent),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                element.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SceneTokens.sceneTitle(
                  17,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  element.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    13,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 项目类型（范式/栈/模板）卡片。
class SceneTypeCard extends StatelessWidget {
  const SceneTypeCard({
    super.key,
    required this.scene,
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final SceneDefinition scene;
  final SceneProjectType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return SelectableShell(
      selected: selected,
      accent: scene.accent,
      child: GlassCard(
        onTap: onTap,
        accent: scene.accent,
        radius: SceneTokens.radiusMedium,
        padding: EdgeInsets.zero,
        semanticLabel: '选择项目类型 ${type.name}',
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      type.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SceneTokens.sceneTitle(
                        17,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  if (type.badge != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scene.accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        type.badge!,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: scene.accent,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  SelectDot(selected: selected, accent: scene.accent),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: Text(
                  type.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    13,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 向导底部操作栏：上一步 + 继续/完成。
class SceneWizardBottomBar extends StatelessWidget {
  const SceneWizardBottomBar({
    super.key,
    required this.compact,
    required this.accent,
    required this.canContinue,
    required this.submitting,
    required this.isLast,
    required this.onBack,
    required this.onNext,
    this.backEnabled = true,
  });

  final bool compact;
  final Color accent;
  final bool canContinue;
  final bool submitting;
  final bool isLast;
  final VoidCallback onBack;
  final VoidCallback onNext;

  /// 是否允许「上一步」。
  final bool backEnabled;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final enabled = canContinue && !submitting;
    final nextButton = SizedBox(
      height: compact ? 52 : 48,
      child: FilledButton(
        onPressed: enabled ? onNext : null,
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: palette.bgTop,
          disabledBackgroundColor: palette.glassFill,
          disabledForegroundColor: palette.textTertiary,
          padding: EdgeInsets.symmetric(horizontal: compact ? 18 : 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: submitting
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.bgTop,
                ),
              )
            : Text(isLast ? '完成' : '继续'),
      ),
    );
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 12, compact ? 12 : 16, 12),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(SceneTokens.radiusSmall),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: backEnabled && !submitting ? onBack : null,
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('上一步'),
            style: TextButton.styleFrom(
              foregroundColor: palette.textSecondary,
              disabledForegroundColor: palette.textTertiary,
              textStyle: TextStyle(
                fontSize: compact ? 12.5 : 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (compact) const SizedBox(width: 8) else const Spacer(),
          if (compact) Expanded(child: nextButton) else nextButton,
        ],
      ),
    );
  }
}
