import 'dart:async';

import 'package:flutter/material.dart';

/// 打字机文字效果
///
/// 逐字显示 [text]，带闪烁光标；text 变化时重新播放。
class TypewriterText extends StatefulWidget {
  const TypewriterText({
    super.key,
    required this.text,
    this.style,
    this.charDelay = const Duration(milliseconds: 70),
    this.maxLines = 3,
  });

  final String text;
  final TextStyle? style;

  /// 每个字符的显示间隔
  final Duration charDelay;
  final int maxLines;

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  String _shown = '';
  Timer? _typeTimer;
  Timer? _cursorTimer;
  bool _cursorVisible = true;

  @override
  void initState() {
    super.initState();
    _startTyping();
    _startCursorBlink();
  }

  @override
  void didUpdateWidget(covariant TypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _startTyping();
    }
  }

  void _startTyping() {
    _typeTimer?.cancel();
    _shown = '';
    var index = 0;
    _typeTimer = Timer.periodic(widget.charDelay, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (index >= widget.text.length) {
        timer.cancel();
        return;
      }
      setState(() {
        _shown = widget.text.substring(0, index + 1);
        index++;
      });
    });
  }

  void _startCursorBlink() {
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() => _cursorVisible = !_cursorVisible);
    });
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _cursorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: _shown),
          TextSpan(
            text: '▍',
            style: style.copyWith(
              color: _cursorVisible
                  ? (style.color ?? Colors.blueAccent)
                  : Colors.transparent,
            ),
          ),
        ],
      ),
      style: style,
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }
}
