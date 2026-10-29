/// 语法补全建议
class CompletionItem {
  /// 插入到编辑器的文本
  final String insertText;

  /// 显示在建议列表中的标签（默认与 insertText 相同）
  final String label;

  /// 类型说明（关键字 / 组件 / 片段等），用于列表右侧小字
  final String kind;

  /// 补充说明（可选）
  final String? detail;

  const CompletionItem({
    required this.insertText,
    String? label,
    this.kind = '关键字',
    this.detail,
  }) : label = label ?? insertText;
}

/// Flutter / Dart 语法补全服务
///
/// 纯本地规则引擎，不依赖 LSP / 分析服务器：
/// 根据光标前的「部分标识符」从内置关键字、常用 Widget、
/// 代码片段中前缀匹配，返回排序后的建议列表。
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

  /// 常用 Flutter Widget
  static const _flutterWidgets = <String>[
    'Align', 'AppBar', 'AspectRatio', 'Baseline', 'BottomNavigationBar',
    'BottomSheet', 'Card', 'Center', 'Checkbox', 'Chip', 'CircleAvatar',
    'ClipRRect', 'Column', 'Container', 'Divider', 'Drawer', 'ElevatedButton',
    'Expanded', 'FilledButton', 'Flexible', 'FloatingActionButton', 'Form',
    'FutureBuilder', 'GestureDetector', 'GridView', 'Icon', 'IconButton',
    'Image', 'InkWell', 'LinearProgressIndicator', 'ListTile', 'ListView',
    'MaterialApp', 'Navigator', 'Opacity', 'OutlinedButton', 'Padding',
    'Placeholder', 'Positioned', 'Radio', 'RichText', 'Row', 'SafeArea',
    'Scaffold', 'SizedBox', 'Slider', 'SnackBar', 'Spacer', 'Stack',
    'StatefulWidget', 'StatelessWidget', 'StreamBuilder', 'Switch', 'TabBar',
    'TabBarView', 'Text', 'TextButton', 'TextField', 'Tooltip', 'Wrap',
  ];

  /// 常用代码片段（label → insertText）
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
    'build': '@override\nWidget build(BuildContext context) {\n  return \${1:child};\n}',
    'initState': '@override\nvoid initState() {\n  super.initState();\n  \${1:}\n}',
    'dispose': '@override\nvoid dispose() {\n  \${1:}\n  super.dispose();\n}',
    'setState': 'setState(() {\n  \${1:}\n});',
    'print': "print('\${1:debug}');",
    'try': 'try {\n  \${1:}\n} catch (e) {\n  \${2:}\n}',
  };

  // ---------------------------------------------------------------------------
  // 补全逻辑
  // ---------------------------------------------------------------------------

  /// 判断当前光标位置是否适合触发补全
  ///
  /// 规则：光标前必须是「部分标识符」（字母/数字/_），且前面是标识符起始
  /// 或 `.`（成员访问）/`(`（参数）/`,`（参数列表）/空白。
  bool shouldTrigger(String text, int cursorOffset) {
    if (cursorOffset <= 0 || cursorOffset > text.length) return false;
    final prefix = _identifierPrefix(text, cursorOffset);
    return prefix.isNotEmpty;
  }

  /// 根据光标前的部分标识符返回补全建议
  List<CompletionItem> complete(String text, int cursorOffset) {
    final prefix = _identifierPrefix(text, cursorOffset);
    if (prefix.isEmpty) return const [];
    final lower = prefix.toLowerCase();
    final isMemberAccess =
        cursorOffset > prefix.length &&
            text[cursorOffset - prefix.length - 1] == '.';

    final items = <CompletionItem>[];

    // 成员访问时给出常用属性/方法
    if (isMemberAccess) {
      items.addAll(_memberSuggestions(lower));
    } else {
      // 1) Dart 关键字
      for (final kw in _dartKeywords) {
        if (kw.startsWith(lower)) {
          items.add(CompletionItem(insertText: kw, kind: '关键字'));
        }
      }
      // 2) Flutter Widget（区分大小写前缀匹配）
      for (final w in _flutterWidgets) {
        if (w.toLowerCase().startsWith(lower)) {
          items.add(CompletionItem(
            insertText: w,
            kind: '组件',
            detail: 'Flutter Widget',
          ));
        }
      }
      // 3) 代码片段
      _snippets.forEach((trigger, body) {
        if (trigger.toLowerCase().startsWith(lower)) {
          items.add(CompletionItem(
            insertText: body,
            label: trigger,
            kind: '片段',
            detail: '代码模板',
          ));
        }
      });
    }

    // 排序：完全前缀匹配 > 长度短的 > 字典序
    items.sort((a, b) {
      final aExact = a.label.toLowerCase() == lower ? 0 : 1;
      final bExact = b.label.toLowerCase() == lower ? 0 : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);
      final len = a.label.length.compareTo(b.label.length);
      if (len != 0) return len;
      return a.label.compareTo(b.label);
    });
    return items.take(20).toList();
  }

  /// 提取光标前的部分标识符
  String _identifierPrefix(String text, int cursorOffset) {
    if (cursorOffset > text.length) return '';
    var i = cursorOffset;
    while (i > 0) {
      final ch = text[i - 1];
      final isIdent = (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) || // 0-9
          (ch.codeUnitAt(0) >= 65 && ch.codeUnitAt(0) <= 90) || // A-Z
          (ch.codeUnitAt(0) >= 97 && ch.codeUnitAt(0) <= 122) || // a-z
          ch == '_';
      if (!isIdent) break;
      i--;
    }
    return text.substring(i, cursorOffset);
  }

  /// 成员访问建议（`object.` 后）
  List<CompletionItem> _memberSuggestions(String lower) {
    const members = <String, String>{
      'add': 'List 方法',
      'addAll': 'List 方法',
      'build': 'State / StatelessWidget',
      'clear': 'List / Map 方法',
      'contains': 'List / String 方法',
      'copyWith': '复制并修改字段',
      'dispose': 'State 生命周期',
      'first': 'Iterable 属性',
      'forEach': 'Iterable 方法',
      'initState': 'State 生命周期',
      'isEmpty': 'Iterable / String 属性',
      'isNotEmpty': 'Iterable / String 属性',
      'last': 'Iterable 属性',
      'length': 'Iterable / String 属性',
      'map': 'Iterable 转换',
      'push': 'Navigator 方法',
      'remove': 'List / Map 方法',
      'setState': 'State 方法',
      'split': 'String 方法',
      'substring': 'String 方法',
      'toJson': '序列化',
      'toString': 'Object 方法',
      'where': 'Iterable 过滤',
    };
    final items = <CompletionItem>[];
    members.forEach((name, kind) {
      if (name.toLowerCase().startsWith(lower)) {
        items.add(CompletionItem(insertText: name, kind: kind));
      }
    });
    return items;
  }
}
