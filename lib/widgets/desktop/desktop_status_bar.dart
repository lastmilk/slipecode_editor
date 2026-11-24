import 'package:flutter/material.dart';

/// 底部状态栏：左侧放语言/LSP/构建，右侧放行列/缩进/编码等。
class DesktopStatusBar extends StatelessWidget {
  final List<Widget> left;
  final List<Widget> right;

  const DesktopStatusBar({
    super.key,
    this.left = const [],
    this.right = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.9),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(children: [...left, const Spacer(), ...right]),
    );
  }

  static Widget item(
    String text, {
    IconData? icon,
    VoidCallback? onTap,
    String? tooltip,
  }) {
    return Builder(
      builder: (context) {
        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 12,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
            ],
          ),
        );
        final tappable = onTap == null
            ? content
            : InkWell(onTap: onTap, child: content);
        return tooltip == null
            ? tappable
            : Tooltip(message: tooltip, child: tappable);
      },
    );
  }
}
