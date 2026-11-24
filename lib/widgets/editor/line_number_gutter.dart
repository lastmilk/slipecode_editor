import 'package:flutter/material.dart';

import '../../models/editor_diagnostic.dart';
import 'line_layout.dart';

/// 行号槽：按换行 + 实际换行高度对齐（支持软换行）
///
/// 通过 [TextPainter.getOffsetForCaret] 取得每一逻辑行的 y 偏移，
/// 因此长行被软换行时行号也不会错位。
class LineNumberGutter extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// 编辑器滚动控制器（用于行号跟随滚动）
  final ScrollController scrollController;

  /// 文本区域内部宽度（用于还原换行）
  final double layoutWidth;

  /// 左右内边距（与 TextField contentPadding 一致）
  final double topPadding;

  /// 槽宽
  final double width;

  /// 当前行（1 基，0 表示不高亮）
  final int activeLine;

  /// 诊断标记
  final List<EditorDiagnostic> diagnostics;

  final Color background;
  final Color foreground;
  final Color activeForeground;
  final Color borderColor;

  const LineNumberGutter({
    super.key,
    required this.text,
    required this.style,
    required this.scrollController,
    required this.layoutWidth,
    required this.width,
    required this.background,
    required this.foreground,
    required this.activeForeground,
    required this.borderColor,
    this.topPadding = 12,
    this.activeLine = 0,
    this.diagnostics = const [],
  });

  @override
  State<LineNumberGutter> createState() => _LineNumberGutterState();
}

class _LineNumberGutterState extends State<LineNumberGutter> {
  List<double> _tops = const [0];
  double _lineHeight = 20;
  int _lineCount = 1;

  String? _cachedText;
  TextStyle? _cachedStyle;
  double _cachedWidth = -1;

  void _ensureLayout() {
    final width = widget.layoutWidth;
    if (_cachedText == widget.text &&
        _cachedStyle == widget.style &&
        (_cachedWidth - width).abs() < 0.5) {
      return;
    }
    _cachedText = widget.text;
    _cachedStyle = widget.style;
    _cachedWidth = width;

    final layout = computeLineLayout(
      text: widget.text,
      style: widget.style,
      maxWidth: width,
    );
    _tops = layout.tops;
    _lineHeight = layout.lineHeight;
    _lineCount = layout.lineCount;
  }

  Map<int, Color> _lineMarkers() {
    final markers = <int, Color>{};
    for (final diagnostic in widget.diagnostics) {
      final line = diagnostic.start.line + 1;
      final color = diagnostic.isError
          ? const Color(0xFFE51400)
          : diagnostic.isWarning
              ? const Color(0xFFBF8803)
              : const Color(0xFF1A85FF);
      final existing = markers[line];
      if (existing == null || diagnostic.isError) {
        markers[line] = color;
      }
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    _ensureLayout();
    final markers = _lineMarkers();
    final digitCount = '$_lineCount'.length;
    final fontSize = (widget.style.fontSize ?? 13) - 1.5;

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: widget.background,
        border: Border(
          right: BorderSide(color: widget.borderColor, width: 0.6),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: widget.scrollController,
            builder: (context, _) {
              final scroll = widget.scrollController.hasClients
                  ? widget.scrollController.offset
                  : 0.0;
              final height = constraints.maxHeight;
              final items = <Widget>[];
              for (var i = 0; i < _tops.length; i++) {
                final top = widget.topPadding + _tops[i] - scroll;
                if (top < -_lineHeight || top > height) continue;
                final line = i + 1;
                final active = line == widget.activeLine;
                items.add(
                  Positioned(
                    top: top,
                    right: 6 + (digitCount - 1) * 1.5,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (markers.containsKey(line))
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: markers[line],
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        Text(
                          '$line',
                          style: TextStyle(
                            fontSize: fontSize,
                            height: 1.5,
                            fontFamily: widget.style.fontFamily,
                            color: active
                                ? widget.activeForeground
                                : widget.foreground,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ClipRect(child: Stack(children: items));
            },
          );
        },
      ),
    );
  }
}
