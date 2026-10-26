import 'package:flutter/material.dart';

/// 代码编辑器组件
///
/// 基于 TextField 实现纯文本编辑，语法高亮由 SyntaxService 单独处理
class CodeEditor extends StatefulWidget {
  final String initialContent;
  final String? language;
  final Function(String)? onChanged;
  final bool readOnly;
  final int? maxLines;

  const CodeEditor({
    super.key,
    this.initialContent = '',
    this.language = 'dart',
    this.onChanged,
    this.readOnly = false,
    this.maxLines,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textColor = isDark ? const Color(0xFFD4D4D4) : Colors.black;

    return Container(
      color: bgColor,
      child: TextField(
        controller: _controller,
        style: TextStyle(
          fontSize: 14,
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
      ),
    );
  }
}
