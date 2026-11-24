import 'package:flutter/material.dart';

/// 可拖拽分隔条：支持水平（左右拖动）与垂直（上下拖动）。
///
/// 尺寸由父级约束决定：水平分隔条宽 5px、高度由 Row 的 stretch 拉伸；
/// 垂直分隔条高 5px、宽度由 Column 的 stretch 拉伸。避免使用
/// `double.infinity` 造成布局反复求解。
class ResizableSplit extends StatefulWidget {
  final Axis axis;
  final ValueChanged<double> onDelta;
  final VoidCallback? onReset;
  final Color? color;

  const ResizableSplit({
    super.key,
    required this.axis,
    required this.onDelta,
    this.onReset,
    this.color,
  });

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<ResizableSplit> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = widget.axis == Axis.horizontal;
    final active = _hovering || _dragging;
    final color = active
        ? theme.colorScheme.primary.withValues(alpha: 0.35)
        : (widget.color ?? theme.dividerColor);

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: horizontal
            ? (_) => setState(() => _dragging = true)
            : null,
        onHorizontalDragEnd: horizontal
            ? (_) => setState(() => _dragging = false)
            : null,
        onHorizontalDragUpdate: horizontal
            ? (details) => widget.onDelta(details.delta.dx)
            : null,
        onVerticalDragStart: horizontal
            ? null
            : (_) => setState(() => _dragging = true),
        onVerticalDragEnd: horizontal
            ? null
            : (_) => setState(() => _dragging = false),
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => widget.onDelta(details.delta.dy),
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: horizontal ? 5 : null,
          height: horizontal ? null : 5,
          child: ColoredBox(color: color),
        ),
      ),
    );
  }
}
