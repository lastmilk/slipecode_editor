import 'dart:io';

import 'package:flutter/material.dart';

import '../services/completion_service.dart';

/// 代码编辑器组件
///
/// 基于 TextField 实现纯文本编辑，内置 Flutter/Dart 语法补全：
/// - 输入时根据光标前的部分标识符弹出建议列表
/// - 点击建议或按 Tab / 音量上键（Android）接受补全
/// - iOS 在建议条上提供「⌘ 补全」虚拟按钮
class CodeEditor extends StatefulWidget {
  final String initialContent;
  final String? language;
  final Function(String)? onChanged;
  final bool readOnly;
  final int? maxLines;

  /// 代码字号（来自偏好设置）
  final double fontSize;

  /// 是否启用代码补全（来自偏好设置）
  final bool enableCompletion;

  /// 音量键回调：返回 true 表示消费了这次按键（接受了补全或插入 Tab）。
  /// 由外部（EditorScreen）注入，State 里注册。
  final bool Function()? onVolumeUpKey;

  /// 音量下键是否也要拦截（通常 false，只处理音量上键）
  final bool Function()? onVolumeDownKey;

  const CodeEditor({
    super.key,
    this.initialContent = '',
    this.language = 'dart',
    this.onChanged,
    this.readOnly = false,
    this.maxLines,
    this.fontSize = 14,
    this.enableCompletion = true,
    this.onVolumeUpKey,
    this.onVolumeDownKey,
  });

  @override
  State<CodeEditor> createState() => CodeEditorState();
}

/// 公开 State 类，供 EditorScreen 通过 GlobalKey 调用
/// [acceptSuggestionOrTab] 等方法（音量键补全）。
class CodeEditorState extends State<CodeEditor> {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  /// 当前补全建议（空列表表示无建议）
  List<CompletionItem> _suggestions = [];

  /// 当前建议对应的部分标识符起始位置（用于替换）
  int _prefixStart = 0;

  /// 是否手动关闭了建议条（Esc / 点击空白）
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialContent != widget.initialContent &&
        _controller.text != widget.initialContent) {
      _controller.value = TextEditingValue(text: widget.initialContent);
    }
  }

  // ---------------------------------------------------------------------------
  // 补全逻辑
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    if (!widget.enableCompletion || widget.readOnly) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final service = CompletionService.instance;
    if (!service.shouldTrigger(text, cursor)) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final items = service.complete(text, cursor);
    final prefix = _identifierPrefix(text, cursor);
    setState(() {
      _suggestions = items;
      _prefixStart = cursor - prefix.length;
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

  /// 接受一条建议：替换光标前的部分标识符
  void _acceptSuggestion(CompletionItem item) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < _prefixStart) return;

    // 片段里的 ${1:xxx} 占位符简化处理：去掉标记，直接插入内容
    var insert = item.insertText;
    insert = insert.replaceAllMapped(
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
    setState(() => _suggestions = []);
  }

  /// 在光标处插入 Tab（两个空格）
  void insertTab() {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) return;
    const tab = '  ';
    final newText = text.replaceRange(cursor, cursor, tab);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor + tab.length),
    );
    widget.onChanged?.call(newText);
  }

  /// 当前是否有可见的补全建议（供编辑器页判断音量键行为）
  bool get hasSuggestions => _suggestions.isNotEmpty && !_dismissed;

  /// 供外部（音量上键）调用：
  /// - 有建议时接受第一条，返回 true（消费按键）
  /// - 无建议且 [fallbackToTab] 为 true 时插入 Tab，返回 true
  /// - 否则返回 false（放行系统音量调节）
  bool acceptSuggestionOrTab({bool fallbackToTab = true}) {
    if (hasSuggestions) {
      _acceptSuggestion(_suggestions.first);
      return true;
    }
    if (fallbackToTab) {
      insertTab();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textColor = isDark ? const Color(0xFFD4D4D4) : Colors.black;

    return Container(
      color: bgColor,
      child: Column(
        children: [
          // 补全建议条（仅在输入中且有建议时显示）
          if (widget.enableCompletion && hasSuggestions)
            _buildSuggestionBar(isDark),

          // 编辑区
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: TextStyle(
                fontSize: widget.fontSize,
                height: 1.5,
                color: textColor,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(12),
                isDense: true,
              ),
              maxLines: widget.maxLines,
              minLines: 1,
              expands: widget.maxLines == null,
              readOnly: widget.readOnly,
              keyboardType: TextInputType.multiline,
              enableInteractiveSelection: true,
              onChanged: widget.onChanged,
              onTap: () {
                // 点击移动光标后重新计算补全
                _onTextChanged();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部建议条：横向滚动，点击接受；iOS 额外提供「接受」按钮
  Widget _buildSuggestionBar(bool isDark) {
    final barColor = isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3);
    final borderColor =
        isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E0E0);

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: barColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // 建议列表
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _suggestions.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final item = _suggestions[index];
                return Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _acceptSuggestion(item),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: index == 0
                            ? Colors.blueAccent.withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: index == 0
                              ? Colors.blueAccent
                              : borderColor,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: index == 0
                                  ? Colors.blueAccent
                                  : (isDark ? Colors.white70 : Colors.black87),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            item.kind,
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  isDark ? Colors.white38 : Colors.black38,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // iOS：音量键不可用，提供虚拟「接受补全」按钮
          if (Platform.isIOS)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                onPressed: _suggestions.isEmpty
                    ? null
                    : () => _acceptSuggestion(_suggestions.first),
                icon: const Icon(Icons.keyboard_return, size: 14),
                label: const Text('补全', style: TextStyle(fontSize: 11)),
              ),
            ),

          // 关闭建议条
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
