import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' as hl;

/// Dart 语法高亮服务
///
/// 使用 highlight 包（highlight.js 的 Dart 移植版）进行 token 化，
/// 然后映射到 TextStyle 颜色
class SyntaxService {
  SyntaxService._();

  // 深色主题颜色映射
  static const Map<String, Color> _darkColors = {
    'keyword': Color(0xFF569CD6),
    'built_in': Color(0xFF4EC9B0),
    'string': Color(0xFFCE9178),
    'comment': Color(0xFF6A9955),
    'number': Color(0xFFB5CEA8),
    'meta': Color(0xFFDCDCAA),
    'title': Color(0xFFDCDCAA),
    'function': Color(0xFFDCDCAA),
    'class': Color(0xFF4EC9B0),
    'variable': Color(0xFF9CDCFE),
    'punctuation': Color(0xFFD4D4D4),
  };

  // 浅色主题颜色
  static const Map<String, Color> _lightColors = {
    'keyword': Color(0xFF0000FF),
    'built_in': Color(0xFF267F99),
    'string': Color(0xFFA31515),
    'comment': Color(0xFF008000),
    'number': Color(0xFF098658),
    'meta': Color(0xFFAF00DB),
    'title': Color(0xFF795E26),
    'function': Color(0xFF795E26),
    'class': Color(0xFF267F99),
    'variable': Color(0xFF001080),
    'punctuation': Color(0xFF000000),
  };

  /// 对代码进行高亮，返回 TextSpan 列表
  static TextSpan highlight(
    String code, {
    String language = 'dart',
    bool isDark = true,
  }) {
    final themeColors = isDark ? _darkColors : _lightColors;
    final defaultColor = isDark ? const Color(0xFFD4D4D4) : Colors.black;

    // 基础样式
    const baseStyle = TextStyle(
      fontSize: 14,
      height: 1.5,
      fontFamily: 'monospace',
    );

    try {
      final result = hl.highlight.parse(code, language: language);
      final children = _convertNodes(result.nodes ?? [], themeColors, defaultColor);
      return TextSpan(
        style: baseStyle.copyWith(color: defaultColor),
        children: children,
      );
    } catch (e) {
      // 高亮失败时返回纯文本
      return TextSpan(
        style: baseStyle.copyWith(color: defaultColor),
        text: code,
      );
    }
  }

  static List<TextSpan> _convertNodes(
    List<hl.Node> nodes,
    Map<String, Color> themeColors,
    Color defaultColor,
  ) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      spans.addAll(_processNode(node, themeColors, defaultColor));
    }
    return spans;
  }

  static List<TextSpan> _processNode(
    hl.Node node,
    Map<String, Color> themeColors,
    Color defaultColor,
  ) {
    final spans = <TextSpan>[];

    // 确定当前颜色
    Color currentColor = defaultColor;
    if (node.className != null && node.className!.isNotEmpty) {
      // highlight 输出的 className 是 'hljs-keyword' 格式，去掉 hljs- 前缀
      final cleanName = node.className!.replaceFirst('hljs-', '');
      currentColor = themeColors[cleanName] ?? defaultColor;
    }

    if (node.children != null && node.children!.isNotEmpty) {
      // 有子节点，递归处理
      for (final child in node.children!) {
        spans.addAll(_processNode(child, themeColors, defaultColor));
      }
    } else if (node.value != null) {
      spans.add(TextSpan(
        text: node.value,
        style: TextStyle(color: currentColor),
      ));
    }

    return spans;
  }
}
