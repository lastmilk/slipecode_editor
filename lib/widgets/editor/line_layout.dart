import 'package:flutter/material.dart';

/// 行号布局结果
class LineLayout {
  /// 每个逻辑行在文本中的 y 偏移（相对文本顶部）
  final List<double> tops;

  /// 单行高度
  final double lineHeight;

  /// 逻辑行数
  final int lineCount;

  /// 是否存在软换行（长行被折行）
  final bool wrapped;

  const LineLayout({
    required this.tops,
    required this.lineHeight,
    required this.lineCount,
    required this.wrapped,
  });
}

/// 计算行号槽的每行位置
///
/// 绝大多数代码没有软换行，此时每行间隔等于行高，
/// 可以直接推导，无需对每一行调用 [TextPainter.getOffsetForCaret]。
/// 只有检测到软换行时才逐行查询真实的 y 偏移。
LineLayout computeLineLayout({
  required String text,
  required TextStyle style,
  required double maxWidth,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth < 1 ? 1 : maxWidth);

  final lineHeight = painter.preferredLineHeight;
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) starts.add(i + 1);
  }
  final lineCount = starts.length;

  // 文本实际高度明显大于「行数 × 行高」说明发生了软换行
  final wrapped = text.isNotEmpty &&
      painter.height - lineCount * lineHeight > 0.5;

  final List<double> tops;
  if (wrapped) {
    tops = [
      for (final start in starts)
        painter
            .getOffsetForCaret(
              TextPosition(offset: start.clamp(0, text.length)),
              Rect.zero,
            )
            .dy,
    ];
  } else {
    tops = [for (var i = 0; i < lineCount; i++) i * lineHeight];
  }

  painter.dispose();
  return LineLayout(
    tops: tops,
    lineHeight: lineHeight,
    lineCount: lineCount,
    wrapped: wrapped,
  );
}
