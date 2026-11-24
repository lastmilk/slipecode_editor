import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';
import 'package:window_manager/window_manager.dart';

/// 自绘桌面标题栏（Windows / Linux）
///
/// 不使用系统默认标题栏，而是由 Flutter 绘制：
/// 最左侧为「形态切换」按钮（CDE ⇄ SOLO），其后是菜单、项目名、搜索与窗口控件。
/// 空白区域可拖拽移动窗口，双击可最大化 / 还原。
class DesktopTitleBar extends StatelessWidget {
  const DesktopTitleBar({
    super.key,
    required this.brand,
    required this.menus,
    this.title = '',
    this.titleLeading,
    this.search,
    this.actions = const [],
    this.height = 40,
    this.background,
    this.foreground,
    this.onSettings,
    this.onProjectMenu,
  });

  /// 最左侧的品牌 / 形态切换按钮
  final Widget brand;

  /// 菜单（文件 / 编辑 / …）
  final List<Widget> menus;

  /// 项目名
  final String title;

  /// 项目名前面的小图标（可选）
  final Widget? titleLeading;

  /// 搜索入口（可选，通常是按钮或搜索框）
  final Widget? search;

  /// 右侧操作区（搜索之前的自定义按钮）
  final List<Widget> actions;

  final double height;
  final Color? background;
  final Color? foreground;

  /// 「设置」按钮回调（为空时不响应）
  final VoidCallback? onSettings;

  /// 点击项目名时打开多项目管理菜单（为空时不可点击）
  final void Function(BuildContext anchor)? onProjectMenu;

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg =
        background ??
        (isDark ? const Color(0xFF1B1B1F) : const Color(0xFFF7F7F9));
    final fg = foreground ?? (isDark ? Colors.white70 : Colors.black87);

    return Container(
      height: height,
      color: bg,
      child: Row(
        children: [
          // 最左侧：形态切换按钮（固定宽度，与活动栏对齐）
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 4),
            child: brand,
          ),
          ...menus,
          const SizedBox(width: 8),
          // 项目名 + 空白区域：整体都是拖拽区，双击最大化
          Expanded(
            child: _DeferredDragArea(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: _toggleMaximize,
                child: Container(
                  height: height,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      _ProjectTitle(
                        title: title,
                        titleLeading: titleLeading,
                        foreground: fg,
                        onTap: onProjectMenu == null
                            ? null
                            : () => onProjectMenu!(context),
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ...actions,
          if (search != null) ...[search!, const SizedBox(width: 4)],
          if (onSettings != null) ...[
            IconButton(
              tooltip: '设置',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.settings_outlined, size: 16, color: fg),
              onPressed: () => _openSettings(context),
            ),
            const SizedBox(width: 4),
          ],
          _WindowButton(
            tooltip: '最小化',
            color: fg,
            icon: Icons.remove,
            onPressed: () => windowManager.minimize(),
          ),
          _WindowButton(
            tooltip: '最大化 / 还原',
            color: fg,
            icon: Icons.crop_square,
            onPressed: _toggleMaximize,
          ),
          _WindowButton(
            tooltip: '关闭',
            color: fg,
            icon: Icons.close,
            hoverColor: const Color(0xFFE81123),
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }

  /// 设置入口（由宿主注入）
  void _openSettings(BuildContext context) {
    onSettings?.call();
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.color,
    this.hoverColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color color;
  final Color? hoverColor;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 44,
            height: 40,
            alignment: Alignment.center,
            color: _hovered
                ? (widget.hoverColor ?? Colors.black12)
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovered && widget.hoverColor != null
                  ? Colors.white
                  : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题栏中的项目名：可点击打开多项目管理菜单（VS Code / TRAE 风格）
class _ProjectTitle extends StatefulWidget {
  const _ProjectTitle({
    required this.title,
    required this.titleLeading,
    required this.foreground,
    required this.isDark,
    this.onTap,
  });

  final String title;
  final Widget? titleLeading;
  final Color foreground;
  final bool isDark;
  final VoidCallback? onTap;

  @override
  State<_ProjectTitle> createState() => _ProjectTitleState();
}

class _ProjectTitleState extends State<_ProjectTitle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clickable = widget.onTap != null;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.titleLeading != null) ...[
          widget.titleLeading!,
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: widget.foreground,
            ),
          ),
        ),
        if (clickable) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.arrow_drop_down,
            size: 16,
            color: widget.foreground.withValues(alpha: 0.7),
          ),
        ],
      ],
    );

    if (!clickable) return content;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovering
                ? (widget.isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _hovering
                  ? theme.dividerColor
                  : Colors.transparent,
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 标题栏拖拽区：只有真正拖动后才进入系统窗口移动循环。
///
/// 直接使用 [DragToMoveArea] 会在「按下即拖」时立刻调用 `startDragging`，
/// 在部分 Wayland 合成器上可能长时间占住输入抓取，导致后续点击全部失效。
/// 这里改为手势越过拖动阈值后才触发。
class _DeferredDragArea extends StatefulWidget {
  const _DeferredDragArea({required this.child});

  final Widget child;

  @override
  State<_DeferredDragArea> createState() => _DeferredDragAreaState();
}

class _DeferredDragAreaState extends State<_DeferredDragArea> {
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _armed = true,
      onPointerUp: (_) => _armed = false,
      onPointerCancel: (_) => _armed = false,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (details) {
          if (!_armed) return;
          if (details.delta.distanceSquared < 1) return;
          _armed = false;
          windowManager.startDragging();
        },
        child: widget.child,
      ),
    );
  }
}
