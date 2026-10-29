import 'package:flutter/material.dart';

/// 语法高亮配色
class SyntaxColors {
  final Color plain;
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color type;
  final Color annotation;

  const SyntaxColors({
    required this.plain,
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.type,
    required this.annotation,
  });

  /// 按主题生成一套配色（VS Code 风格，深浅各一套）
  factory SyntaxColors.of({required bool isDark}) {
    if (isDark) {
      return const SyntaxColors(
        plain: Color(0xFFD4D4D4),
        comment: Color(0xFF6A9955),
        string: Color(0xFFCE9178),
        number: Color(0xFFB5CEA8),
        keyword: Color(0xFF569CD6),
        type: Color(0xFF4EC9B0),
        annotation: Color(0xFFDCDCAA),
      );
    }
    return const SyntaxColors(
      plain: Color(0xFF1F2328),
      comment: Color(0xFF6A737D),
      string: Color(0xFF032F62),
      number: Color(0xFF005CC5),
      keyword: Color(0xFFD73A49),
      type: Color(0xFF005CC5),
      annotation: Color(0xFF6F42C1),
    );
  }
}

/// 语法高亮 TextEditingController
///
/// 使用正则分词器在渲染时给注释、字符串、数字、关键字、类型、注解上色，
/// 不改变文本内容与光标行为。
class HighlightingController extends TextEditingController {
  HighlightingController({
    required String text,
    required this.language,
    required this.colors,
  }) : super(text: text);

  /// 语言标识（dart / kotlin / java / yaml / json / markdown / plaintext）
  String language;

  /// 当前配色
  SyntaxColors colors;

  /// 切换到新语言并触发重绘
  void setLanguage(String value) {
    if (language == value) return;
    language = value;
    notifyListeners();
  }

  static const _dartKeywords = <String>{
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide',
    'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
    'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
    'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
    'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when',
    'while', 'with', 'yield',
  };

  static const _jvmKeywords = <String>{
    'abstract', 'annotation', 'boolean', 'break', 'byte', 'case', 'catch',
    'char', 'class', 'companion', 'const', 'continue', 'data', 'default', 'do',
    'double', 'else', 'enum', 'extends', 'final', 'finally', 'float', 'for',
    'fun', 'if', 'implements', 'import', 'in', 'int', 'interface', 'internal',
    'is', 'lateinit', 'long', 'object', 'open', 'override', 'package',
    'private', 'protected', 'public', 'return', 'sealed', 'short', 'static',
    'super', 'this', 'throw', 'try', 'val', 'var', 'void', 'when', 'while',
  };

  static const _yamlKeywords = <String>{
    'true', 'false', 'null', 'yes', 'no', 'on', 'off',
  };

  /// 单个正则覆盖所有可上色片段（顺序即优先级）
  static final _tokenPattern = RegExp(
    r'''//[^\n]*|/\*[\s\S]*?\*/|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|@[A-Za-z_]\w*|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b''',
  );

  Set<String> get _keywords => switch (language) {
        'dart' => _dartKeywords,
        'kotlin' || 'java' => _jvmKeywords,
        'yaml' => _yamlKeywords,
        'json' => _yamlKeywords,
        _ => const <String>{},
      };

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? const TextStyle();
    // 纯文本语言不做分词，直接走默认实现（性能更好）
    if (language == 'plaintext') {
      return super.buildTextSpan(
        context: context,
        style: baseStyle.copyWith(color: colors.plain),
        withComposing: withComposing,
      );
    }

    final text = value.text;
    final keywords = _keywords;
    final spans = <TextSpan>[];
    var index = 0;

    for (final match in _tokenPattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(
          text: text.substring(index, match.start),
          style: baseStyle.copyWith(color: colors.plain),
        ));
      }
      final token = match.group(0)!;
      spans.add(TextSpan(
        text: token,
        style: baseStyle.copyWith(color: _colorFor(token, keywords)),
      ));
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(
        text: text.substring(index),
        style: baseStyle.copyWith(color: colors.plain),
      ));
    }

    return TextSpan(style: baseStyle, children: spans);
  }

  Color _colorFor(String token, Set<String> keywords) {
    if (token.startsWith('//') || token.startsWith('/*')) {
      return colors.comment;
    }
    if (token.startsWith("'") || token.startsWith('"')) {
      return colors.string;
    }
    if (token.startsWith('@')) {
      return colors.annotation;
    }
    final code = token.codeUnitAt(0);
    // 数字
    if (code >= 48 && code <= 57) return colors.number;
    if (keywords.contains(token)) return colors.keyword;
    // 首字母大写视为类型/Widget
    if (code >= 65 && code <= 90) return colors.type;
    return colors.plain;
  }
}
