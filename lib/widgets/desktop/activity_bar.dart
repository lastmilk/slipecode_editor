import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class ActivityBarItem {
  final IconData icon;
  final String tooltip;
  final int? badge;
  final VoidCallback onTap;

  /// 是否为「跳转页」按钮：点击后打开独立页面，不参与侧边栏选中态。
  final bool pushNavigation;

  const ActivityBarItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge,
    this.pushNavigation = false,
  });
}

/// 活动栏（资源管理器 / 搜索 / 工具链 / 插件 / 构建）。
///
/// 视觉参考 VS Code：48px 宽，每个条目等高 48px，
/// 选中态为整块圆角高亮 + 最外侧 2px 强调条（不会把高亮压扁）。
/// [onRight] 为 true 时用于 SOLO 布局的右侧镜像（边框与强调条换边）。
class ActivityBar extends StatelessWidget {
  final List<ActivityBarItem> items;
  final int selectedIndex;
  final VoidCallback? onSettings;
  final VoidCallback? onToggleTheme;
  final bool onRight;

  const ActivityBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    this.onSettings,
    this.onToggleTheme,
    this.onRight = false,
  });

  static const double width = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF333333) : const Color(0xFFE8E8E8),
        border: Border(
          right: onRight
              ? BorderSide.none
              : BorderSide(color: theme.dividerColor),
          left: onRight
              ? BorderSide(color: theme.dividerColor)
              : BorderSide.none,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            const SizedBox(height: 4),
            for (var i = 0; i < items.length; i++)
              _ActivityButton(
                item: items[i],
                selected: !items[i].pushNavigation && i == selectedIndex,
                onRight: onRight,
              ),
            const Spacer(),
            if (onToggleTheme != null)
              _BottomButton(
                icon: dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                tooltip: 'Theme',
                onTap: onToggleTheme!,
              ),
            if (onSettings != null)
              _BottomButton(
                icon: Icons.settings_outlined,
                tooltip: t('settings.title'),
                onTap: onSettings!,
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _ActivityButton extends StatefulWidget {
  final ActivityBarItem item;
  final bool selected;
  final bool onRight;

  const _ActivityButton({
    required this.item,
    required this.selected,
    required this.onRight,
  });

  @override
  State<_ActivityButton> createState() => _ActivityButtonState();
}

class _ActivityButtonState extends State<_ActivityButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;
    final background = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.16)
        : (_hovering
              ? theme.colorScheme.onSurface.withValues(alpha: 0.07)
              : Colors.transparent);
    return Tooltip(
      message: widget.item.tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: SizedBox(
        width: ActivityBar.width,
        height: 48,
        child: Stack(
          children: [
            // 最外侧强调条：占满整个条目高度，不被圆角裁切
            Positioned(
              left: widget.onRight ? null : 0,
              right: widget.onRight ? 0 : null,
              top: 0,
              bottom: 0,
              child: Container(
                width: 2,
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              child: Material(
                color: background,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: widget.item.onTap,
                  onHover: (value) => setState(() => _hovering = value),
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        widget.item.icon,
                        size: 22,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      if (widget.item.badge != null &&
                          widget.item.badge! > 0)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.error,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${widget.item.badge}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomButton extends StatelessWidget {
  const _BottomButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon),
      onPressed: onTap,
    );
  }
}
