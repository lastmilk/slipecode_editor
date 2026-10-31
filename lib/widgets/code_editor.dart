import 'dart:io';

import 'package:flutter/material.dart';

import '../services/completion_service.dart';
import 'code_highlighter.dart';

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

  @override
  void initState() {
    super.initState();
    _colors = SyntaxColors.of(isDark: false);
    _lastText = widget.initialContent;
    _controller = HighlightingController(
      text: widget.initialContent,
      language: widget.language,
      colors: _colors,
    );
    _controller.addListener(_onTextChanged);
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
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _suggestionScroll.dispose();
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

    final lineStart = lineEnd == 0 ? 0 : text.lastIndexOf('\n', lineEnd - 1) + 1;
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
  // 补全逻辑
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    _detectVibeOnEnter();
    if (!widget.enableCompletion || widget.readOnly) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    final text = _controller.text;
    final service = CompletionService.instance;
    if (!service.shouldTrigger(text, cursor)) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    final items = service.complete(
      text,
      cursor,
      language: widget.language,
    );
    final prefix = _identifierPrefix(text, cursor);
    setState(() {
      _suggestions = items;
      _prefixStart = cursor - prefix.length;
      _selectedIndex = 0;
      _dismissed = false;
    });
  }

  String _identifierPrefix(String text, int cursorOffset) {
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

    return Container(
      color: background,
      child: Column(
        children: [
          if (widget.enableCompletion && hasSuggestions)
            _buildSuggestionBar(isDark),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: TextStyle(
                fontSize: widget.fontSize,
                height: 1.5,
                color: _colors.plain,
                fontFamily: widget.fontFamily.isEmpty
                    ? 'monospace'
                    : widget.fontFamily,
              ),
              cursorColor: isDark ? Colors.white70 : Colors.black87,
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
              onTap: _onTextChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// 建议条：横向候选，当前项高亮；Android 提示音量键用法，iOS 提供虚拟按钮
  Widget _buildSuggestionBar(bool isDark) {
    final barColor = isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3);
    final borderColor =
        isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E0E0);
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

