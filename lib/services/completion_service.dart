/// 补全建议类型
enum CompletionKind { keyword, widget, snippet, identifier, member }

/// 语法补全建议
class CompletionItem {
  /// 插入到编辑器的文本
  final String insertText;

  /// 显示在建议列表中的标签（默认与 insertText 相同）
  final String label;

  /// 类型说明（关键字 / 组件 / 片段等），用于列表右侧小字
  final String kindLabel;

  /// 补充说明（可选）
  final String? detail;

  final CompletionKind kind;

  const CompletionItem({
    required this.insertText,
    String? label,
    this.kindLabel = '关键字',
    this.detail,
    this.kind = CompletionKind.keyword,
  }) : label = label ?? insertText;
}

/// Flutter / Dart 语法补全服务
///
/// 纯本地规则引擎，不依赖 LSP / 分析服务器：
/// - 内置关键字、常用 Widget、代码片段
/// - 从当前文档提取类名/变量名/方法名作为候选（近似语义补全）
/// - 支持成员访问（`obj.`）的常用属性与方法建议
/// - 支持驼峰首字母匹配（`cbb` → `createBottomBar`）
class CompletionService {
  CompletionService._();

  static final CompletionService instance = CompletionService._();

  // ---------------------------------------------------------------------------
  // 内置词库
  // ---------------------------------------------------------------------------

  /// Dart 关键字
  static const _dartKeywords = <String>[
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide',
    'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
    'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
    'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
    'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when',
    'while', 'with', 'yield',
  ];

  /// Kotlin / Java 关键字
  static const _jvmKeywords = <String>[
    'abstract', 'annotation', 'boolean', 'break', 'byte', 'case', 'catch',
    'char', 'class', 'companion', 'const', 'continue', 'data', 'default', 'do',
    'double', 'else', 'enum', 'extends', 'final', 'finally', 'float', 'for',
    'fun', 'if', 'implements', 'import', 'in', 'int', 'interface', 'internal',
    'is', 'lateinit', 'long', 'object', 'open', 'override', 'package',
    'private', 'protected', 'public', 'return', 'sealed', 'short', 'static',
    'super', 'this', 'throw', 'try', 'val', 'var', 'void', 'when', 'while',
  ];

  /// 其它语言的常用字面量关键字
  static const _literalKeywords = <String>[
    'true', 'false', 'null', 'none', 'nil', 'undefined',
  ];

  /// 常用 Flutter Widget
  static const _flutterWidgets = <String>[
    'Align', 'AnimatedContainer', 'AppBar', 'AspectRatio', 'Baseline',
    'BottomNavigationBar', 'BottomSheet', 'Card', 'Center', 'Checkbox', 'Chip',
    'CircleAvatar', 'ClipRRect', 'Column', 'Container', 'Divider', 'Drawer',
    'ElevatedButton', 'Expanded', 'FilledButton', 'Flexible',
    'FloatingActionButton', 'Form', 'FutureBuilder', 'GestureDetector',
    'GridView', 'Icon', 'IconButton', 'Image', 'InkWell',
    'LinearProgressIndicator', 'ListTile', 'ListView', 'MaterialApp',
    'Navigator', 'Opacity', 'OutlinedButton', 'Padding', 'PageView',
    'Placeholder', 'Positioned', 'Radio', 'RichText', 'Row', 'SafeArea',
    'Scaffold', 'SingleChildScrollView', 'SizedBox', 'Slider', 'SnackBar',
    'Spacer', 'Stack', 'StatefulWidget', 'StatelessWidget', 'StreamBuilder',
    'Switch', 'TabBar', 'TabBarView', 'Text', 'TextButton', 'TextField',
    'Tooltip', 'Wrap',
  ];

  /// 常用代码片段（触发词 → 插入内容，`${1:xx}` 为占位符）
  static const _snippets = <String, String>{
    'stless': 'class \${1:MyWidget} extends StatelessWidget {\n'
        '  const \${1:MyWidget}({super.key});\n\n'
        '  @override\n'
        '  Widget build(BuildContext context) {\n'
        '    return const \${2:Placeholder}();\n'
        '  }\n'
        '}',
    'stful': 'class \${1:MyWidget} extends StatefulWidget {\n'
        '  const \${1:MyWidget}({super.key});\n\n'
        '  @override\n'
        '  State<\${1:MyWidget}> createState() => _\${1:MyWidget}State();\n'
        '}\n\n'
        'class _\${1:MyWidget}State extends State<\${1:MyWidget}> {\n'
        '  @override\n'
        '  Widget build(BuildContext context) {\n'
        '    return const \${2:Placeholder}();\n'
        '  }\n'
        '}',
    'main': 'void main() {\n  runApp(const \${1:MyApp}());\n}',
    'build': '@override\n'
        'Widget build(BuildContext context) {\n  return \${1:child};\n}',
    'initstate': '@override\nvoid initState() {\n  super.initState();\n  \${1:}\n}',
    'dispose': '@override\nvoid dispose() {\n  \${1:}\n  super.dispose();\n}',
    'setstate': 'setState(() {\n  \${1:}\n});',
    'print': "print('\${1:debug}');",
    'try': 'try {\n  \${1:}\n} catch (e) {\n  \${2:}\n}',
    'ifelse': 'if (\${1:condition}) {\n  \${2:}\n} else {\n  \${3:}\n}',
  };

  /// 成员访问建议（`obj.` 之后）
  static const _members = <String, String>{
    'add': 'List 方法',
    'addAll': 'List 方法',
    'animateTo': 'TabController 方法',
    'build': 'State / Widget',
    'clear': 'List / Map 方法',
    'contains': 'List / String 方法',
    'copyWith': '复制并修改字段',
    'dispose': 'State 生命周期',
    'first': 'Iterable 属性',
    'forEach': 'Iterable 方法',
    'initState': 'State 生命周期',
    'insert': 'List 方法',
    'isEmpty': 'Iterable / String 属性',
    'isNotEmpty': 'Iterable / String 属性',
    'join': 'Iterable 方法',
    'keys': 'Map 属性',
    'last': 'Iterable 属性',
    'length': 'Iterable / String 属性',
    'map': 'Iterable 转换',
    'notifyListeners': 'ChangeNotifier 方法',
    'push': 'Navigator 方法',
    'pushReplacement': 'Navigator 方法',
    'remove': 'List / Map 方法',
    'removeAt': 'List 方法',
    'replaceAll': 'String 方法',
    'setState': 'State 方法',
    'split': 'String 方法',
    'substring': 'String 方法',
    'toJson': '序列化',
    'toLowerCase': 'String 方法',
    'toString': 'Object 方法',
    'toUpperCase': 'String 方法',
    'trim': 'String 方法',
    'values': 'Map 属性',
    'where': 'Iterable 过滤',
  };

  // ---------------------------------------------------------------------------
  // 补全逻辑
  // ---------------------------------------------------------------------------

  /// 判断当前光标位置是否适合触发补全
  bool shouldTrigger(String text, int cursorOffset) {
    if (cursorOffset <= 0 || cursorOffset > text.length) return false;
    return _identifierPrefix(text, cursorOffset).isNotEmpty;
  }

  /// 根据光标前的部分标识符返回补全建议
  ///
  /// [language] 用于选择关键字集合（dart / kotlin / java / yaml / json ...）。
  List<CompletionItem> complete(
    String text,
    int cursorOffset, {
    String language = 'dart',
  }) {
    final prefix = _identifierPrefix(text, cursorOffset);
    if (prefix.isEmpty) return const [];
    final lower = prefix.toLowerCase();
    final isMemberAccess =
        cursorOffset > prefix.length &&
        text[cursorOffset - prefix.length - 1] == '.';

    final items = <CompletionItem>[];

    if (isMemberAccess) {
      // 成员访问：只给属性/方法建议
      _members.forEach((name, kind) {
        if (_matches(name, lower)) {
          items.add(CompletionItem(
            insertText: name,
            kindLabel: kind,
            kind: CompletionKind.member,
          ));
        }
      });
      return _sorted(items, lower).take(24).toList();
    }

    // 1) 当前文档里出现过的标识符（类名 / 变量 / 方法名）
    items.addAll(_documentIdentifiers(text, lower, cursorOffset));

    if (language == 'dart') {
      // 2) Dart 关键字
      for (final kw in _dartKeywords) {
        if (_matches(kw, lower)) {
          items.add(CompletionItem(insertText: kw));
        }
      }
      // 3) Flutter Widget（首字母大写，按类型标注）
      for (final w in _flutterWidgets) {
        if (_matches(w, lower)) {
          items.add(CompletionItem(
            insertText: w,
            kindLabel: '组件',
            detail: 'Flutter Widget',
            kind: CompletionKind.widget,
          ));
        }
      }
      // 4) 代码片段（触发词不区分大小写）
      _snippets.forEach((trigger, body) {
        if (trigger.startsWith(lower)) {
          items.add(CompletionItem(
            insertText: body,
            label: trigger,
            kindLabel: '片段',
            detail: '代码模板',
            kind: CompletionKind.snippet,
          ));
        }
      });
    } else if (language == 'kotlin' || language == 'java') {
      for (final kw in _jvmKeywords) {
        if (_matches(kw, lower)) {
          items.add(CompletionItem(insertText: kw));
        }
      }
      for (final kw in _literalKeywords) {
        if (_matches(kw, lower)) {
          items.add(CompletionItem(
            insertText: kw,
            kindLabel: '字面量',
            kind: CompletionKind.keyword,
          ));
        }
      }
    } else {
      for (final kw in _literalKeywords) {
        if (_matches(kw, lower)) {
          items.add(CompletionItem(
            insertText: kw,
            kindLabel: '字面量',
            kind: CompletionKind.keyword,
          ));
        }
      }
    }

    return _sorted(items, lower).take(24).toList();
  }

  /// 前缀匹配：普通前缀 或 驼峰首字母匹配
  bool _matches(String candidate, String lowerPrefix) {
    final lower = candidate.toLowerCase();
    if (lower.startsWith(lowerPrefix)) return true;
    // 驼峰首字母匹配：cbb → createBottomBar
    if (lowerPrefix.length >= 2) {
      final initials = StringBuffer();
      var atBoundary = true;
      for (final ch in candidate.split('')) {
        if (atBoundary && ch.trim().isNotEmpty && ch != '_') {
          initials.write(ch.toLowerCase());
          atBoundary = false;
        } else if (ch == '_' || ch == ch.toUpperCase()) {
          atBoundary = true;
        }
      }
      return initials.toString().startsWith(lowerPrefix);
    }
    return false;
  }

  /// 打分排序：前缀完全匹配 > 短 > 字典序
  List<CompletionItem> _sorted(List<CompletionItem> items, String lower) {
    // 去重（同一个 insertText 只保留第一个）
    final seen = <String>{};
    final unique = <CompletionItem>[];
    for (final item in items) {
      final key = '${item.kind.name}:${item.label}';
      if (seen.add(key)) unique.add(item);
    }
    unique.sort((a, b) {
      final aExact = a.label.toLowerCase() == lower ? 0 : 1;
      final bExact = b.label.toLowerCase() == lower ? 0 : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);
      // 文档标识符优先于关键字（更贴近用户上下文）
      final rank = _kindRank(a.kind).compareTo(_kindRank(b.kind));
      if (rank != 0) return rank;
      final len = a.label.length.compareTo(b.label.length);
      if (len != 0) return len;
      return a.label.compareTo(b.label);
    });
    return unique;
  }

  int _kindRank(CompletionKind kind) => switch (kind) {
        CompletionKind.identifier => 0,
        CompletionKind.widget => 1,
        CompletionKind.snippet => 2,
        CompletionKind.member => 3,
        CompletionKind.keyword => 4,
      };

  /// 从文档中提取标识符（类名、变量名、方法名）
  List<CompletionItem> _documentIdentifiers(
    String text,
    String lower,
    int cursorOffset,
  ) {
    final items = <CompletionItem>[];
    // class Foo / enum Foo / mixin Foo / typedef Foo
    final typePattern =
        RegExp(r'\b(?:class|enum|mixin|typedef|extension)\s+([A-Za-z_]\w*)');
    for (final m in typePattern.allMatches(text)) {
      final name = m.group(1)!;
      if (_matches(name, lower)) {
        items.add(CompletionItem(
          insertText: name,
          kindLabel: '类型',
          kind: CompletionKind.identifier,
        ));
      }
    }
    // final/var/const/late 声明的变量
    final varPattern = RegExp(
      r'\b(?:final|var|const|late)\s+(?:[A-Za-z_][\w<>, ?]*\s+)?([A-Za-z_]\w*)\s*[=;]',
    );
    for (final m in varPattern.allMatches(text)) {
      final name = m.group(1)!;
      if (_matches(name, lower)) {
        items.add(CompletionItem(
          insertText: name,
          kindLabel: '变量',
          kind: CompletionKind.identifier,
        ));
      }
    }
    // 方法/函数声明：Type name(
    final fnPattern = RegExp(
      r'\b(?:void|int|double|String|bool|Future|Widget|dynamic)\s+([A-Za-z_]\w*)\s*\(',
    );
    for (final m in fnPattern.allMatches(text)) {
      final name = m.group(1)!;
      if (_matches(name, lower)) {
        items.add(CompletionItem(
          insertText: '$name()',
          label: name,
          kindLabel: '方法',
          kind: CompletionKind.identifier,
        ));
      }
    }
    return items;
  }

  /// 提取光标前的部分标识符
  String _identifierPrefix(String text, int cursorOffset) {
    if (cursorOffset > text.length) return '';
    var i = cursorOffset;
    while (i > 0) {
      final ch = text[i - 1];
      final isIdent = (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) ||
          (ch.codeUnitAt(0) >= 65 && ch.codeUnitAt(0) <= 90) ||
          (ch.codeUnitAt(0) >= 97 && ch.codeUnitAt(0) <= 122) ||
          ch == '_';
      if (!isIdent) break;
      i--;
    }
    return text.substring(i, cursorOffset);
  }
}
