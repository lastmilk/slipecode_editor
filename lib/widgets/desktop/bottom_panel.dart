import 'package:flutter/material.dart';

class BottomPanelTab {
  final String label;
  final IconData icon;
  final int? badge;
  final Widget child;

  const BottomPanelTab({
    required this.label,
    required this.icon,
    required this.child,
    this.badge,
  });
}

/// 底部面板：问题 / 输出 / 终端 / 构建。
class BottomPanel extends StatefulWidget {
  final List<BottomPanelTab> tabs;
  final VoidCallback? onClose;

  /// 初始选中的页（外部通过 key 变更可切换页签）
  final int initialIndex;

  /// 页签切换回调（供外部同步状态）
  final ValueChanged<int>? onTabChanged;

  const BottomPanel({
    super.key,
    required this.tabs,
    this.onClose,
    this.initialIndex = 0,
    this.onTabChanged,
  });

  @override
  State<BottomPanel> createState() => _BottomPanelState();
}

class _BottomPanelState extends State<BottomPanel> {
  late int _selected = widget.tabs.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, widget.tabs.length - 1);

  @override
  void didUpdateWidget(covariant BottomPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected >= widget.tabs.length) {
      _selected = widget.tabs.isEmpty ? 0 : widget.tabs.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 4),
                for (var i = 0; i < widget.tabs.length; i++)
                  _TabButton(
                    tab: widget.tabs[i],
                    selected: i == _selected,
                    onTap: () {
                      setState(() => _selected = i);
                      widget.onTabChanged?.call(i);
                    },
                  ),
                const Spacer(),
                if (widget.onClose != null)
                  IconButton(
                    iconSize: 16,
                    tooltip: 'Close panel',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: IndexedStack(
              index: _selected,
              sizing: StackFit.expand,
              children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  // 隐藏页签内的动画（进度圈、终端光标等）必须停摆，
                  // 否则每一帧都会驱动整窗重建，导致输入迟滞
                  TickerMode(
                    enabled: i == _selected,
                    child: widget.tabs[i].child,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final BottomPanelTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 14,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 11,
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (tab.badge != null && tab.badge! > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${tab.badge}',
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
