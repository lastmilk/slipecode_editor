import 'package:flutter/material.dart';

/// 通用日志控制台
///
/// 深色背景、等宽字体、自动滚动到底部
class LogConsole extends StatefulWidget {
  final List<String> lines;
  final String emptyText;
  final double fontSize;

  const LogConsole({
    super.key,
    required this.lines,
    this.emptyText = '暂无输出',
    this.fontSize = 12,
  });

  @override
  State<LogConsole> createState() => _LogConsoleState();
}

class _LogConsoleState extends State<LogConsole> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(LogConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines.length != widget.lines.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _colorFor(String line) {
    final lower = line.toLowerCase();
    if (line.startsWith('[ERROR]') ||
        lower.contains('error:') ||
        lower.contains('failed') ||
        lower.contains('失败')) {
      return const Color(0xFFFF6B6B);
    }
    if (line.startsWith('==>') || line.startsWith('[正在')) {
      return const Color(0xFF4EC9B0);
    }
    if (line.startsWith('\$ ')) {
      return const Color(0xFFDCDCAA);
    }
    if (line.startsWith('警告')) {
      return const Color(0xFFFFC66D);
    }
    return const Color(0xFFD4D4D4);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2E2E2E)),
      ),
      padding: const EdgeInsets.all(10),
      child: widget.lines.isEmpty
          ? Center(
              child: Text(
                widget.emptyText,
                style: TextStyle(
                  color: Colors.white24,
                  fontSize: widget.fontSize,
                  fontFamily: 'monospace',
                ),
              ),
            )
          : ListView.builder(
              controller: _controller,
              itemCount: widget.lines.length,
              itemBuilder: (context, index) {
                final line = widget.lines[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: TextStyle(
                      color: _colorFor(line),
                      fontSize: widget.fontSize,
                      fontFamily: 'monospace',
                      height: 1.35,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
