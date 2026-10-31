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

  /// JavaScript / TypeScript 关键字（Node.js、HTML、Taro 载荷）
  static const _jsKeywords = <String>{
    'abstract', 'any', 'as', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'debugger', 'declare', 'default', 'delete',
    'do', 'else', 'enum', 'export', 'extends', 'false', 'finally', 'for',
    'from', 'function', 'if', 'implements', 'import', 'in', 'instanceof',
    'interface', 'keyof', 'let', 'new', 'null', 'of', 'private', 'protected',
    'public', 'readonly', 'return', 'static', 'super', 'switch', 'this',
    'throw', 'true', 'try', 'type', 'typeof', 'undefined', 'var', 'void',
    'while', 'yield',
  };

  /// 代码类语言（Dart / JVM / JS）的通用分词正则
  static final _codePattern = RegExp(
    r'''//[^\n]*|/\*[\s\S]*?\*/|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|@[A-Za-z_]\w*|\b\d+(?:\.\d+)?\b|\b[A-Za-z_]\w*\b''',
  );

  /// JSON：字符串 / 数字 / 字面量 / 注释
  static final _jsonPattern = RegExp(
    r'''//[^\n]*|"(?:[^"\\\n]|\\.)*"|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|\b(?:true|false|null)\b''',
  );

  /// XML / HTML：注释、声明、标签、实体
  static final _xmlPattern = RegExp(
    r'''<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<![^>]*>|<[^>]*>|&[#A-Za-z0-9]+;''',
  );

  static final _xmlInnerPattern = RegExp(
    r'''"[^"]*"|'[^']*'|[A-Za-z_:][\w:.-]*|=|/|[\s\S]''',
  );

  /// YAML：字符串、注释、数字、布尔、键
  static final _yamlPattern = RegExp(
    r'''"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|#[^\n]*|\b\d+(?:\.\d+)?\b|\b(?:true|false|null|yes|no|on|off)\b|[A-Za-z_][\w.-]*|[&*!][A-Za-z_]\w*|[|>][-+]?|[\[\]{}]''',
  );

  /// Markdown：标题、代码块、行内代码、粗体、链接、引用、列表
  static final _markdownPattern = RegExp(
    r'''```[\s\S]*?```|^#{1,6}[^\n]*|`[^`\n]*`|<!--[\s\S]*?-->|\*\*[^\n*]*\*\*|__[^\n_]*__|\[[^\]\n]*\]\([^)]*\)|^>[^\n]*|^[ \t]*(?:[-*+]|\d+\.)[ \t]''',
    multiLine: true,
  );

  Set<String> get _keywords => switch (language) {
        'dart' => _dartKeywords,
        'kotlin' || 'java' => _jvmKeywords,
        'yaml' => _yamlKeywords,
        'json' => _yamlKeywords,
        'javascript' || 'typescript' => _jsKeywords,
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
    switch (language) {
      case 'json':
        return _buildJson(text, baseStyle);
      case 'xml':
      case 'html':
      case 'svg':
        return _buildXml(text, baseStyle);
      case 'yaml':
        return _buildYaml(text, baseStyle);
      case 'markdown':
      case 'md':
        return _buildMarkdown(text, baseStyle);
      default:
        return _buildCode(text, baseStyle);
    }
  }

  /// 通用：按正则扫描并逐段上色
  TextSpan _scan(
    String text,
    TextStyle baseStyle,
    RegExp pattern,
    Color Function(String token, int start) colorOf,
  ) {
    final spans = <TextSpan>[];
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(
          text: text.substring(index, match.start),
          style: baseStyle.copyWith(color: colors.plain),
        ));
      }
      final token = match.group(0)!;
      spans.add(TextSpan(
        text: token,
        style: baseStyle.copyWith(color: colorOf(token, match.start)),
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

  TextSpan _buildCode(String text, TextStyle baseStyle) {
    final keywords = _keywords;
    return _scan(text, baseStyle, _codePattern, (token, _) {
      if (token.startsWith('//') || token.startsWith('/*')) {
        return colors.comment;
      }
      if (token.startsWith("'") || token.startsWith('"')) return colors.string;
      if (token.startsWith('@')) return colors.annotation;
      final code = token.codeUnitAt(0);
      if (code >= 48 && code <= 57) return colors.number;
      if (keywords.contains(token)) return colors.keyword;
      // 首字母大写视为类型/Widget
      if (code >= 65 && code <= 90) return colors.type;
      return colors.plain;
    });
  }

  TextSpan _buildJson(String text, TextStyle baseStyle) {
    return _scan(text, baseStyle, _jsonPattern, (token, start) {
      if (token.startsWith('//')) return colors.comment;
      if (token.startsWith('"')) {
        // 形如 "key": 的字符串按对象键上色
        final after = text.substring(start + token.length);
        final trimmed = after.replaceFirst(RegExp(r'^\s*'), '');
        if (trimmed.startsWith(':')) return colors.type;
        return colors.string;
      }
      final code = token.codeUnitAt(0);
      if (code >= 48 && code <= 57) return colors.number;
      return colors.keyword; // true / false / null
    });
  }

  TextSpan _buildXml(String text, TextStyle baseStyle) {
    final spans = <TextSpan>[];
    var index = 0;
    for (final match in _xmlPattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(
          text: text.substring(index, match.start),
          style: baseStyle.copyWith(color: colors.plain),
        ));
      }
      final token = match.group(0)!;
      if (token.startsWith('<!--') || token.startsWith('<?') ||
          token.startsWith('<!')) {
        spans.add(TextSpan(
          text: token,
          style: baseStyle.copyWith(color: colors.comment),
        ));
      } else if (token.startsWith('&')) {
        spans.add(TextSpan(
          text: token,
          style: baseStyle.copyWith(color: colors.annotation),
        ));
      } else {
        spans.addAll(_xmlTagSpans(token, baseStyle));
      }
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

  /// 标签内部：标签名（类型色）、属性名（注解色）、属性值（字符串色）
  List<TextSpan> _xmlTagSpans(String tag, TextStyle baseStyle) {
    final spans = <TextSpan>[];
    var seenName = false;
    for (final match in _xmlInnerPattern.allMatches(tag)) {
      final token = match.group(0)!;
      Color color;
      if (token.startsWith('"') || token.startsWith("'")) {
        color = colors.string;
      } else if (RegExp(r'^[A-Za-z_:]').hasMatch(token)) {
        if (!seenName) {
          seenName = true;
          color = colors.type;
        } else {
          color = colors.annotation;
        }
      } else if (token == '<' || token == '>' || token == '/' || token == '=') {
        color = colors.keyword;
      } else {
        color = colors.plain;
      }
      spans.add(TextSpan(
        text: token,
        style: baseStyle.copyWith(color: color),
      ));
    }
    return spans;
  }

  TextSpan _buildYaml(String text, TextStyle baseStyle) {
    return _scan(text, baseStyle, _yamlPattern, (token, start) {
      if (token.startsWith('#')) return colors.comment;
      if (token.startsWith('"') || token.startsWith("'")) return colors.string;
      final code = token.codeUnitAt(0);
      if (code >= 48 && code <= 57) return colors.number;
      // 位于行首（允许缩进）且后面紧跟冒号的标识符视为键
      final lineStart =
          text.lastIndexOf('\n', start < 0 ? 0 : start) + 1;
      final prefix = text.substring(lineStart, start);
      final after = text.substring(start + token.length);
      if (prefix.trim().isEmpty &&
          after.replaceFirst(RegExp(r'^\s*'), '').startsWith(':')) {
        return colors.type;
      }
      if (_yamlKeywords.contains(token)) return colors.keyword;
      if (token.startsWith('&') || token.startsWith('*') || token.startsWith('!')) {
        return colors.annotation;
      }
      return colors.plain;
    });
  }

  TextSpan _buildMarkdown(String text, TextStyle baseStyle) {
    return _scan(text, baseStyle, _markdownPattern, (token, _) {
      if (token.startsWith('```')) return colors.type;
      if (token.startsWith('<!--')) return colors.comment;
      if (token.startsWith('#')) return colors.keyword;
      if (token.startsWith('`')) return colors.string;
      if (token.startsWith('**') || token.startsWith('__')) {
        return colors.annotation;
      }
      if (token.startsWith('[')) return colors.string;
      if (token.startsWith('>')) return colors.comment;
      return colors.keyword; // 列表标记
    });
  }
}
