import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/editor_diagnostic.dart';
import '../models/text_position.dart';
import '../services/completion_service.dart';
import '../services/lsp/semantic_tokens.dart';
import '../services/lua/lua_keyboard_interceptor.dart';
import '../services/lua/lua_runtime_service.dart';
import 'code_highlighter.dart';
import 'editor/find_replace_bar.dart';
import 'editor/line_number_gutter.dart';

/// 代码编辑增强：自动缩进、括号/引号自动闭合
class _CodeEditingFormatter extends TextInputFormatter {
  const _CodeEditingFormatter();

  static const _closingFor = <String, String>{
    '(': ')',
    '[': ']',
    '{': '}',
    '"': '"',
    "'": "'",
    '`': '`',
  };

  static const _closings = {')', ']', '}', '"', "'", '`'};

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    // 只处理「插入一个字符」的编辑
    if (newText.length != oldText.length + 1 ||
        !newValue.selection.isCollapsed) {
      return newValue;
    }
    final offset = newValue.selection.baseOffset;
    if (offset <= 0 || offset > newText.length) return newValue;
    final typed = newText[offset - 1];

    // 自动闭合产生的右半边：再次输入时直接跳过
    if (_closings.contains(typed) &&
        offset - 1 < oldText.length &&
        oldText[offset - 1] == typed) {
      return TextEditingValue(
        text: oldText,
        selection: TextSelection.collapsed(offset: offset),
      );
    }

    // 换行：沿用上一行缩进，块起始符后额外缩进
    if (typed == '\n') {
      final previousStart = oldText.lastIndexOf('\n', offset - 2) + 1;
      final previousLine = oldText.substring(previousStart, offset - 1);
      final indent = RegExp(r'^[ \t]*').stringMatch(previousLine) ?? '';
      final trimmed = previousLine.trimRight();
      final extra =
          trimmed.endsWith('{') ||
              trimmed.endsWith('[') ||
              trimmed.endsWith('(')
          ? '  '
          : '';
      final insertion = '$indent$extra';
      if (insertion.isEmpty) return newValue;
      return TextEditingValue(
        text: newText.replaceRange(offset, offset, insertion),
        selection: TextSelection.collapsed(offset: offset + insertion.length),
      );
    }

    // 开括号 / 引号：自动补全另一半
    final closing = _closingFor[typed];
    if (closing != null) {
      return TextEditingValue(
        text: newText.replaceRange(offset, offset, closing),
        selection: TextSelection.collapsed(offset: offset),
      );
    }
    return newValue;
  }
}

/// 代码编辑器组件
///
/// 基于 TextField 实现，包含：
/// - 语法高亮（[HighlightingController]）
/// - 语法/语义补全建议条（音量下键切换候选项，音量上键确认）
/// - iOS 无音量键，建议条提供「上一个 / 下一个 / 补全」虚拟按钮
/// - 可透明背景，让主题背景图透出
class CodeEditor extends StatefulWidget {
  /// 初始内容
  final String initialContent;

  /// 语言标识（dart / kotlin / json / yaml / plaintext ...）
  final String language;

  /// 内容变化回调
  final ValueChanged<String>? onChanged;

  final bool readOnly;

  /// 代码字号
  final double fontSize;

  /// 代码字体族（空字符串使用等宽字体）
  final String fontFamily;

  /// 是否启用补全建议
  final bool enableCompletion;

  /// 是否使用半透明背景（背景图模式下为 true）
  final bool translucent;

  /// VibeCoding 触发回调：用户在行首输入 `..需求` 并回车后调用
  ///
  /// 参数：需求文本、触发词起始偏移、触发词结束偏移（不含换行）。
  final void Function(String requirement, int lineStart, int lineEnd)?
  onVibeRequest;

  /// 是否显示行号槽（桌面宽屏）
  final bool showGutter;

  /// 当前文件的诊断（波浪线 + 行号标记）
  final List<EditorDiagnostic> diagnostics;

  /// 光标位置变化回调（1 基行 / 列）
  final void Function(int line, int column)? onCursorChanged;

  /// 语义高亮 token（桌面 LSP）
  final List<SemanticTokenSpan> semanticTokens;

  /// LSP 补全：返回空列表表示不可用，回退内置补全
  final Future<List<CompletionItem>> Function(String text, int offset)?
  lspCompletion;

  const CodeEditor({
    super.key,
    this.initialContent = '',
    this.language = 'dart',
    this.onChanged,
    this.readOnly = false,
    this.fontSize = 14,
    this.fontFamily = '',
    this.enableCompletion = true,
    this.translucent = false,
    this.onVibeRequest,
    this.showGutter = false,
    this.diagnostics = const [],
    this.onCursorChanged,
    this.semanticTokens = const [],
    this.lspCompletion,
  });

  @override
  State<CodeEditor> createState() => CodeEditorState();
}

/// 公开 State：供 EditorScreen 通过 GlobalKey 驱动音量键行为
class CodeEditorState extends State<CodeEditor> {
  late HighlightingController _controller;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _suggestionScroll = ScrollController();

  /// 当前补全建议
  List<CompletionItem> _suggestions = const [];

  /// 当前选中的建议下标（音量下键循环切换）
  int _selectedIndex = 0;

  /// 建议对应的部分标识符起始位置
  int _prefixStart = 0;

  /// 是否手动关闭了建议条
  bool _dismissed = false;

  bool _isDark = false;
  SyntaxColors _colors = SyntaxColors.of(isDark: false);

  /// 上一次的文本（用于检测「用户刚输入了一个换行」）
  String _lastText = '';

  /// 编辑器滚动控制器（行号槽共用）
  final ScrollController _scrollController = ScrollController();

  /// 大文件模式：关闭高亮诊断与补全，保证输入流畅
  bool _largeFile = false;

  bool _showFindBar = false;
  bool _showReplace = false;

  int _cursorLine = 1;
  int _cursorColumn = 1;

  /// 编辑器整体（用于补全弹层定位）
  final GlobalKey _editorBoxKey = GlobalKey();

  /// 桌面补全弹层
  OverlayEntry? _completionOverlay;
  Offset _completionPosition = Offset.zero;

  /// LSP 补全请求序号（丢弃过期结果）
  int _lspRequestId = 0;
  Timer? _lspDebounce;

  static const int _largeFileThreshold = 2 * 1024 * 1024;

  bool get _isDesktopPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _colors = SyntaxColors.of(isDark: false);
    _lastText = widget.initialContent;
    _largeFile = widget.initialContent.length > _largeFileThreshold;
    _controller = HighlightingController(
      text: widget.initialContent,
      language: widget.language,
      colors: _colors,
    );
    _controller.setDiagnostics(_largeFile ? const [] : widget.diagnostics);
    _controller.setSemanticTokens(
      _largeFile ? const [] : widget.semanticTokens,
    );
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _hideCompletionOverlay();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark != _isDark) {
      _isDark = isDark;
      _colors = SyntaxColors.of(isDark: isDark);
      _controller.colors = _colors;
    }
  }

  @override
  void didUpdateWidget(covariant CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) {
      _controller.setLanguage(widget.language);
    }
    if (oldWidget.initialContent != widget.initialContent &&
        _controller.text != widget.initialContent) {
      _controller.value = TextEditingValue(
        text: widget.initialContent,
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
    if (oldWidget.diagnostics != widget.diagnostics) {
      _controller.setDiagnostics(_largeFile ? const [] : widget.diagnostics);
    }
    if (oldWidget.semanticTokens != widget.semanticTokens) {
      _controller.setSemanticTokens(
        _largeFile ? const [] : widget.semanticTokens,
      );
    }
  }

  @override
  void dispose() {
    _lspDebounce?.cancel();
    _hideCompletionOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _suggestionScroll.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // VibeCoding：输入 `..需求` / `。。需求` 后按回车触发
  // ---------------------------------------------------------------------------

  /// 检测「刚输入了一个换行」且上一行是 `..需求` 触发词
  ///
  /// 只在确实新增了一个换行时触发，避免粘贴多行文本误触发。
  void _detectVibeOnEnter() {
    final text = _controller.text;
    final previous = _lastText;
    _lastText = text;

    if (widget.readOnly || widget.onVibeRequest == null) return;
    final cursor = _controller.selection.baseOffset;
    if (cursor <= 0 || cursor > text.length) return;
    if (text[cursor - 1] != '\n') return;
    // 只处理「在原文本的光标处插入了一个换行」
    if (previous.length + 1 != text.length) return;
    final lineEnd = cursor - 1;
    if (!previous.startsWith(text.substring(0, lineEnd))) return;

    final lineStart = lineEnd == 0
        ? 0
        : text.lastIndexOf('\n', lineEnd - 1) + 1;
    final line = text.substring(lineStart, lineEnd);
    final match = RegExp(r'^\s*(?:\.\.|。。)(.+)$').firstMatch(line);
    if (match == null) return;
    final requirement = match.group(1)!.trim();
    if (requirement.isEmpty) return;

    widget.onVibeRequest!(requirement, lineStart, lineEnd);
  }

  /// 在光标处插入文本（底部符号小键盘使用）
  void insertAtCursor(String text) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    widget.onChanged?.call(newText);
    _focusNode.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // 光标 / 选区 / 查找 API（供桌面命令、LSP 跳转使用）
  // ---------------------------------------------------------------------------

  int get cursorOffset => _controller.selection.baseOffset;

  /// 当前文本（供 LSP 文档同步 / 请求使用）
  String get currentText => _controller.text;

  /// 选区起止（无有效选区时返回光标偏移）
  int get selectionStart => _controller.selection.isValid
      ? _controller.selection.start
      : cursorOffset;

  int get selectionEnd =>
      _controller.selection.isValid ? _controller.selection.end : cursorOffset;

  int get lineCount => '\n'.allMatches(_controller.text).length + 1;

  /// 整体替换文本（LSP 格式化 / Code Action 结果），尽量保留光标位置
  void replaceAllText(String text) {
    if (_controller.text == text) return;
    final offset = _controller.selection.baseOffset;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset.clamp(0, text.length)),
    );
  }

  /// 设置光标 / 选区并聚焦
  void setSelection(int start, int end) {
    final text = _controller.text;
    final base = start.clamp(0, text.length);
    final extent = end.clamp(0, text.length);
    _controller.selection = TextSelection(
      baseOffset: base,
      extentOffset: extent,
    );
    _focusNode.requestFocus();
  }

  /// 显示查找栏（[replace] 为 true 时同时显示替换行）
  void showFind({bool replace = false}) {
    setState(() {
      _showFindBar = true;
      _showReplace = replace || _showReplace;
    });
  }

  void hideFind() {
    setState(() => _showFindBar = false);
  }

  /// 滚动到指定偏移附近（估算行高，够用且无副作用）
  void revealOffset(int offset) {
    if (!_scrollController.hasClients) return;
    final coordinate = TextCoordinate.fromOffset(_controller.text, offset);
    final lineHeight = widget.fontSize * 1.5;
    final target = coordinate.line * lineHeight - 60;
    final position = _scrollController.position;
    _scrollController.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  /// 定位到指定行（1 基）并选中该行
  void revealLine(int line, {int column = 1}) {
    final lines = _controller.text.split('\n');
    final index = (line - 1).clamp(0, lines.length - 1);
    var offset = 0;
    for (var i = 0; i < index; i++) {
      offset += lines[i].length + 1;
    }
    final lineStart = offset;
    final lineEnd = lineStart + lines[index].length;
    final cursor = (lineStart + column - 1).clamp(lineStart, lineEnd);
    setSelection(cursor, cursor);
    revealOffset(lineStart);
  }

  // ---------------------------------------------------------------------------
  // 缩进 / 注释
  // ---------------------------------------------------------------------------

  String get _commentToken {
    switch (widget.language) {
      case 'yaml':
      case 'yml':
        return '#';
      default:
        return '//';
    }
  }

  void _indentSelection() {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    final text = value.text;
    if (selection.isCollapsed) {
      insertAtCursor('  ');
      return;
    }
    final startLine = text.lastIndexOf('\n', selection.start - 1) + 1;
    var endLine = text.indexOf('\n', selection.end);
    if (endLine == -1) endLine = text.length;
    final block = text.substring(startLine, endLine);
    final lineCount = block.split('\n').length;
    final updated = text.replaceRange(
      startLine,
      endLine,
      block.split('\n').map((line) => '  $line').join('\n'),
    );
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: selection.start + 2,
        extentOffset: selection.end + 2 * lineCount,
      ),
    );
  }

  void _outdentSelection() {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    final text = value.text;
    final startLine = text.lastIndexOf('\n', selection.start - 1) + 1;
    var endLine = text.indexOf('\n', selection.end);
    if (endLine == -1) endLine = text.length;
    final block = text.substring(startLine, endLine);
    var removed = 0;
    final updatedBlock = block
        .split('\n')
        .map((line) {
          if (line.startsWith('\t')) {
            removed++;
            return line.substring(1);
          }
          if (line.startsWith('  ')) {
            removed++;
            return line.substring(2);
          }
          if (line.startsWith(' ')) {
            removed++;
            return line.substring(1);
          }
          return line;
        })
        .join('\n');
    if (removed == 0) return;
    final updated = text.replaceRange(startLine, endLine, updatedBlock);
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: (selection.start - 2).clamp(startLine, updated.length),
        extentOffset: (selection.end - 2 * removed).clamp(
          startLine,
          updated.length,
        ),
      ),
    );
  }

  void _toggleComment() {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    final text = value.text;
    final token = _commentToken;
    final startLine = text.lastIndexOf('\n', selection.start - 1) + 1;
    var endLine = text.indexOf('\n', selection.end);
    if (endLine == -1) endLine = text.length;
    final lines = text.substring(startLine, endLine).split('\n');
    final allCommented = lines
        .where((line) => line.trim().isNotEmpty)
        .every((line) => line.trimLeft().startsWith(token));
    final updatedLines = lines
        .map((line) {
          final indent = RegExp(r'^[ \t]*').stringMatch(line) ?? '';
          final body = line.substring(indent.length);
          if (allCommented) {
            if (!body.startsWith(token)) return line;
            final rest = body.substring(token.length);
            return '$indent${rest.startsWith(' ') ? rest.substring(1) : rest}';
          }
          return '$indent$token $body';
        })
        .join('\n');
    final updated = text.replaceRange(startLine, endLine, updatedLines);
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: startLine,
        extentOffset: startLine + updatedLines.length,
      ),
    );
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() {
    final isMac = Platform.isMacOS;
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.tab): _indentSelection,
      const SingleActivator(LogicalKeyboardKey.tab, shift: true):
          _outdentSelection,
      SingleActivator(LogicalKeyboardKey.slash, control: !isMac, meta: isMac):
          _toggleComment,
      SingleActivator(
        LogicalKeyboardKey.keyF,
        control: !isMac,
        meta: isMac,
      ): () =>
          showFind(),
      SingleActivator(
        LogicalKeyboardKey.keyH,
        control: !isMac,
        meta: isMac,
      ): () =>
          showFind(replace: true),
    };
    // 有建议时接管方向键 / Enter / Tab / Esc
    if (hasSuggestions) {
      bindings[const SingleActivator(LogicalKeyboardKey.arrowDown)] = () {
        moveSelection();
      };
      bindings[const SingleActivator(LogicalKeyboardKey.arrowUp)] =
          previousSuggestion;
      bindings[const SingleActivator(LogicalKeyboardKey.enter)] = () {
        acceptSelected();
      };
      bindings[const SingleActivator(LogicalKeyboardKey.tab)] = () {
        acceptSelected();
      };
      bindings[const SingleActivator(LogicalKeyboardKey.escape)] =
          _dismissSuggestions;
    }
    return bindings;
  }

  // ---------------------------------------------------------------------------
  // 补全逻辑
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    _detectVibeOnEnter();
    _refreshCursor();

    final large = _controller.text.length > _largeFileThreshold;
    if (large != _largeFile) {
      _largeFile = large;
      _controller.setDiagnostics(large ? const [] : widget.diagnostics);
      _controller.setSemanticTokens(large ? const [] : widget.semanticTokens);
      if (large) {
        setState(() => _suggestions = const []);
        return;
      }
      setState(() {});
    }
    if (_largeFile) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _updateSuggestions();
  }

  /// 鼠标点击编辑区：只有点击才主动弹出补全
  void _onEditorTap() {
    _onTextChanged();
    if (!widget.enableCompletion || widget.readOnly || _largeFile) return;
    _updateSuggestions(fromClick: true);
  }

  void _refreshCursor() {
    final selection = _controller.selection;
    final offset = selection.isValid ? selection.extentOffset : 0;
    final coordinate = TextCoordinate.fromOffset(_controller.text, offset);
    final line = coordinate.line + 1;
    final column = coordinate.character + 1;
    if (line == _cursorLine && column == _cursorColumn) return;
    final lineChanged = line != _cursorLine;
    _cursorLine = line;
    _cursorColumn = column;
    widget.onCursorChanged?.call(line, column);
    // 行号槽只依赖当前行：同一行内移动光标时无需重建整个编辑器，
    // 否则每次水平移动都会重跑 build（含行号槽整篇布局）。
    if (lineChanged) setState(() {});
  }

  void _updateSuggestions({bool fromClick = false}) {
    if (!widget.enableCompletion || widget.readOnly) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      _hideCompletionOverlay();
      _lspDebounce?.cancel();
      return;
    }
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      _hideCompletionOverlay();
      _lspDebounce?.cancel();
      return;
    }
    final text = _controller.text;
    final service = CompletionService.instance;
    final triggered = service.shouldTrigger(text, cursor);
    // 只有鼠标点击（或补全层已经打开时继续过滤）才展示候选；
    // 光标上下左右移动、普通输入不再自动弹出补全。
    final alreadyOpen = _completionOverlay != null;
    if (!triggered || (!fromClick && !alreadyOpen)) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      _hideCompletionOverlay();
      _lspDebounce?.cancel();
      return;
    }
    final items = service.complete(text, cursor, language: widget.language);
    final prefix = _identifierPrefix(text, cursor);
    setState(() {
      _suggestions = items;
      _prefixStart = cursor - prefix.length;
      _selectedIndex = 0;
      _dismissed = false;
    });
    _syncCompletionOverlay();
    _runCompletionOverride(items, text, cursor, ++_lspRequestId);
    // LSP 触发条件：标识符前缀，或紧跟在触发字符之后（成员访问等）
    const lspTriggerChars = '.(:/{"[=,';
    final previous = cursor > 0 ? text[cursor - 1] : '';
    final lspTriggered =
        triggered ||
        (previous.isNotEmpty && lspTriggerChars.contains(previous));
    if (lspTriggered) {
      _scheduleLspSuggestions(text, cursor);
    } else {
      _lspDebounce?.cancel();
    }
  }

  /// LSP 与内置候选先合并，再统一进入 completion.list 服务链。
  void _scheduleLspSuggestions(String text, int cursor) {
    final request = widget.lspCompletion;
    _lspDebounce?.cancel();
    if (request == null) return;
    final requestId = ++_lspRequestId;
    _lspDebounce = Timer(const Duration(milliseconds: 120), () async {
      List<CompletionItem> lspItems;
      try {
        lspItems = await request(text, cursor);
      } catch (_) {
        return;
      }
      if (!mounted || requestId != _lspRequestId) return;
      if (_controller.selection.baseOffset != cursor) return;
      if (_controller.text != text) return;
      final localItems = CompletionService.instance.complete(
        text,
        cursor,
        language: widget.language,
      );
      final seen = <String>{};
      final items = <CompletionItem>[];
      for (final item in [...lspItems, ...localItems]) {
        if (seen.add('${item.kind.name}:${item.label}:${item.insertText}')) {
          items.add(item);
        }
      }
      await _runCompletionOverride(items, text, cursor, requestId);
    });
  }

  Future<void> _runCompletionOverride(
    List<CompletionItem> items,
    String text,
    int cursor,
    int requestId,
  ) async {
    try {
      final raw = await LuaRuntimeService.instance.registry.invoke(
        'completion',
        'list',
        {
          'language': widget.language,
          'text': text,
          'cursor': cursor,
          'items': [for (final item in items) _completionToJson(item)],
        },
        (request) async => {'items': request['items']},
      );
      if (!mounted || requestId != _lspRequestId) return;
      if (_controller.selection.baseOffset != cursor) return;
      if (_controller.text != text) return;
      if (raw is! Map || raw['items'] is! List) {
        throw const FormatException('completion.list 返回值缺少 items 数组');
      }
      final completed = <CompletionItem>[
        for (final item in raw['items'] as List)
          _completionFromJson(item as Map),
      ];
      final prefix = _identifierPrefix(text, cursor);
      setState(() {
        _suggestions = completed;
        _prefixStart = cursor - prefix.length;
        _selectedIndex = 0;
        _dismissed = false;
      });
      _syncCompletionOverlay();
    } catch (error) {
      debugPrint('Lua completion.list 失败：$error');
    }
  }

  static Map<String, Object?> _completionToJson(CompletionItem item) => {
    'label': item.label,
    'insertText': item.insertText,
    'kindLabel': item.kindLabel,
    if (item.detail != null) 'detail': item.detail,
    'kind': item.kind.name,
  };

  static CompletionItem _completionFromJson(Map<dynamic, dynamic> raw) {
    final insertText = raw['insertText'];
    if (insertText is! String) {
      throw const FormatException('补全项缺少 insertText');
    }
    final kind = CompletionKind.values.where(
      (item) => item.name == raw['kind'],
    );
    return CompletionItem(
      insertText: insertText,
      label: raw['label'] as String? ?? insertText,
      kindLabel: raw['kindLabel'] as String? ?? '插件',
      detail: raw['detail'] as String?,
      kind: kind.isEmpty ? CompletionKind.keyword : kind.first,
    );
  }

  // ---------------------------------------------------------------------------
  // 桌面补全弹层（跟随光标位置）
  // ---------------------------------------------------------------------------

  void _syncCompletionOverlay() {
    if (!mounted) return;
    if (!_isDesktopPlatform || !hasSuggestions || _largeFile) {
      _hideCompletionOverlay();
      return;
    }
    _completionPosition = _computeCompletionPosition();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_completionOverlay == null) {
      _completionOverlay = OverlayEntry(
        builder: (_) => _buildCompletionPopup(),
      );
      overlay.insert(_completionOverlay!);
    } else {
      _completionOverlay!.markNeedsBuild();
    }
  }

  void _hideCompletionOverlay() {
    _completionOverlay?.remove();
    _completionOverlay = null;
  }

  void _dismissSuggestions() {
    if (!hasSuggestions) return;
    setState(() => _dismissed = true);
    _hideCompletionOverlay();
  }

  Offset _computeCompletionPosition() {
    final box = _editorBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return const Offset(120, 120);
    }
    final origin = box.localToGlobal(Offset.zero);
    final gutter = widget.showGutter ? 54.0 : 0.0;
    final innerWidth = (box.size.width - gutter - 24).clamp(
      40.0,
      double.infinity,
    );
    final style = TextStyle(
      fontSize: widget.fontSize,
      height: 1.5,
      fontFamily: widget.fontFamily.isEmpty ? 'monospace' : widget.fontFamily,
    );
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset.clamp(0, text.length);
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: innerWidth);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: cursor),
      Rect.zero,
    );
    painter.dispose();
    final scroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final screenWidth = MediaQuery.of(context).size.width;
    var x = origin.dx + gutter + 12 + caret.dx;
    if (x + 320 > screenWidth) x = (screenWidth - 336).clamp(8.0, screenWidth);
    final y = (origin.dy + 12 + caret.dy + widget.fontSize * 1.7 - scroll)
        .clamp(8.0, MediaQuery.of(context).size.height - 120);
    return Offset(x, y);
  }

  Widget _buildCompletionPopup() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final itemHeight = 26.0;
    return Positioned(
      left: _completionPosition.dx,
      top: _completionPosition.dy,
      child: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(6),
        color: isDark ? const Color(0xFF252526) : Colors.white,
        child: Container(
          width: 320,
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDark ? const Color(0xFF454545) : const Color(0xFFDDDDDD),
            ),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _suggestions.length,
            itemExtent: itemHeight,
            itemBuilder: (context, index) {
              final item = _suggestions[index];
              final selected = index == _selectedIndex;
              return InkWell(
                onTap: () => _applySuggestion(item),
                child: Container(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                            .withValues(alpha: 0.16)
                      : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        _completionIcon(item.kind),
                        size: 14,
                        color: _completionIconColor(item.kind, isDark),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      if (item.detail != null && item.detail!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            item.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? Colors.white38 : Colors.black45,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  IconData _completionIcon(CompletionKind kind) {
    switch (kind) {
      case CompletionKind.widget:
        return Icons.widgets_outlined;
      case CompletionKind.snippet:
        return Icons.bolt;
      case CompletionKind.identifier:
        return Icons.abc;
      case CompletionKind.member:
        return Icons.functions;
      case CompletionKind.keyword:
        return Icons.key;
    }
  }

  Color _completionIconColor(CompletionKind kind, bool isDark) {
    switch (kind) {
      case CompletionKind.widget:
        return const Color(0xFF4EC9B0);
      case CompletionKind.snippet:
        return const Color(0xFFD7BA7D);
      case CompletionKind.identifier:
        return isDark ? Colors.white54 : Colors.black54;
      case CompletionKind.member:
        return const Color(0xFFB180D7);
      case CompletionKind.keyword:
        return const Color(0xFF569CD6);
    }
  }

  String _identifierPrefix(String text, int cursorOffset) {
    var i = cursorOffset;
    while (i > 0) {
      final ch = text[i - 1];
      final isIdent =
          (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) ||
          (ch.codeUnitAt(0) >= 65 && ch.codeUnitAt(0) <= 90) ||
          (ch.codeUnitAt(0) >= 97 && ch.codeUnitAt(0) <= 122) ||
          ch == '_';
      if (!isIdent) break;
      i--;
    }
    return text.substring(i, cursorOffset);
  }

  /// 是否有可见建议
  bool get hasSuggestions => _suggestions.isNotEmpty && !_dismissed;

  /// 当前选中的建议（无建议时为 null）
  CompletionItem? get _current =>
      hasSuggestions ? _suggestions[_selectedIndex] : null;

  /// 音量下键：在候选之间循环切换。返回是否消费了按键。
  bool moveSelection() {
    if (!hasSuggestions) return false;
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _suggestions.length;
    });
    _scrollToSelected();
    _completionOverlay?.markNeedsBuild();
    return true;
  }

  /// 音量上键：确认当前选中的候选。返回是否消费了按键。
  ///
  /// 没有建议时返回 false（由调用方决定是否消费按键）。
  bool acceptSelected() {
    final item = _current;
    if (item == null) return false;
    _applySuggestion(item);
    return true;
  }

  /// 选中上一条（iOS 虚拟按钮用）
  void previousSuggestion() {
    if (!hasSuggestions) return;
    setState(() {
      _selectedIndex =
          (_selectedIndex - 1 + _suggestions.length) % _suggestions.length;
    });
    _scrollToSelected();
    _completionOverlay?.markNeedsBuild();
  }

  /// 选中下一条（iOS 虚拟按钮用）
  void nextSuggestion() => moveSelection();

  void _scrollToSelected() {
    if (!_suggestionScroll.hasClients) return;
    final target = (_selectedIndex * 108.0 - 60).clamp(
      0.0,
      _suggestionScroll.position.maxScrollExtent,
    );
    _suggestionScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  /// 应用一条建议：替换光标前的部分标识符
  void _applySuggestion(CompletionItem item) {
    _hideCompletionOverlay();
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < _prefixStart) return;

    // 片段中的 ${1:xxx} 占位符：保留默认文本
    final insert = item.insertText.replaceAllMapped(
      RegExp(r'\$\{\d+:([^}]*)\}|\$\{\d+\}|\$\d+'),
      (m) => m.group(1) ?? '',
    );

    final newText = text.replaceRange(_prefixStart, cursor, insert);
    final newCursor = _prefixStart + insert.length;
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    widget.onChanged?.call(newText);
    setState(() {
      _suggestions = const [];
      _selectedIndex = 0;
    });
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    // 半透明模式：留出背景图，同时压暗/压亮保证代码可读
    final background = widget.translucent
        ? (isDark
              ? Colors.black.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.55))
        : (isDark ? const Color(0xFF1E1E1E) : Colors.white);

    final textStyle = TextStyle(
      fontSize: widget.fontSize,
      height: 1.5,
      color: _colors.plain,
      fontFamily: widget.fontFamily.isEmpty ? 'monospace' : widget.fontFamily,
    );
    const gutterWidth = 54.0;

    return Container(
      key: _editorBoxKey,
      color: background,
      child: Column(
        children: [
          if (_showFindBar)
            FindReplaceBar(
              controller: _controller,
              showReplace: _showReplace,
              onClose: hideFind,
              onRevealOffset: revealOffset,
            ),
          if (_largeFile)
            Container(
              height: 26,
              alignment: Alignment.center,
              color: isDark ? const Color(0xFF332B00) : const Color(0xFFFFF4CE),
              child: Text(
                t('editor.largeFile'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          if (widget.enableCompletion &&
              hasSuggestions &&
              !_largeFile &&
              !_isDesktopPlatform)
            _buildSuggestionBar(isDark),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final innerWidth =
                    constraints.maxWidth -
                    (widget.showGutter ? gutterWidth : 0) -
                    24;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.showGutter)
                      LineNumberGutter(
                        text: _controller.text,
                        style: textStyle,
                        scrollController: _scrollController,
                        layoutWidth: innerWidth,
                        width: gutterWidth,
                        activeLine: _cursorLine,
                        diagnostics: _largeFile ? const [] : widget.diagnostics,
                        background: isDark
                            ? const Color(0xFF252526)
                            : const Color(0xFFF3F3F3),
                        foreground: isDark ? Colors.white38 : Colors.black38,
                        activeForeground: isDark
                            ? Colors.white70
                            : Colors.black87,
                        borderColor: isDark
                            ? const Color(0xFF3C3C3C)
                            : const Color(0xFFE0E0E0),
                      ),
                    Expanded(
                      child: Focus(
                        skipTraversal: true,
                        onKeyEvent: (node, event) =>
                            LuaKeyboardInterceptor.handle(
                              event,
                              events: LuaRuntimeService.instance.events,
                              bindings: _shortcutBindings(),
                            ),
                        child: CallbackShortcuts(
                          bindings: _shortcutBindings(),
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            scrollController: _scrollController,
                            style: textStyle,
                            inputFormatters: const [_CodeEditingFormatter()],
                            cursorColor: isDark
                                ? Colors.white70
                                : Colors.black87,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.all(12),
                              isDense: true,
                              filled: false,
                            ),
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            readOnly: widget.readOnly,
                            keyboardType: TextInputType.multiline,
                            enableInteractiveSelection: true,
                            onChanged: widget.onChanged,
                            onTap: _onEditorTap,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 建议条：横向候选，当前项高亮；Android 提示音量键用法，iOS 提供虚拟按钮
  Widget _buildSuggestionBar(bool isDark) {
    final barColor = isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3);
    final borderColor = isDark
        ? const Color(0xFF3C3C3C)
        : const Color(0xFFE0E0E0);
    final secondary = isDark ? Colors.white54 : Colors.black54;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: barColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              controller: _suggestionScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _suggestions.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final item = _suggestions[index];
                final selected = index == _selectedIndex;
                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _applySuggestion(item),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.blueAccent.withValues(alpha: 0.18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected ? Colors.blueAccent : borderColor,
                          width: selected ? 1.4 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: widget.fontFamily.isEmpty
                                  ? 'monospace'
                                  : widget.fontFamily,
                              color: selected
                                  ? Colors.blueAccent
                                  : (isDark ? Colors.white70 : Colors.black87),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            item.kindLabel,
                            style: TextStyle(fontSize: 10, color: secondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // iOS 没有音量键：提供上一条 / 下一条 / 补全
          if (Platform.isIOS)
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '上一个',
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                  onPressed: previousSuggestion,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '下一个',
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  onPressed: nextSuggestion,
                ),
                TextButton(
                  onPressed: () {
                    final item = _current;
                    if (item != null) _applySuggestion(item);
                  },
                  child: const Text('补全', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),

          // Android：提示音量键操作
          if (Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '音量↓切换 音量↑确认',
                style: TextStyle(fontSize: 10, color: secondary),
              ),
            ),

          IconButton(
            icon: const Icon(Icons.close, size: 14),
            tooltip: '关闭建议',
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}
