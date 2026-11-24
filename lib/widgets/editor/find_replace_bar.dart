import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 编辑器内查找 / 替换栏
///
/// 直接在 [controller] 上定位与替换，不依赖额外状态副本。
class FindReplaceBar extends StatefulWidget {
  final TextEditingController controller;

  /// 定位到匹配项时回调（用于滚动到可见区域）
  final ValueChanged<int>? onRevealOffset;

  final VoidCallback onClose;

  /// 是否显示替换行
  final bool showReplace;

  const FindReplaceBar({
    super.key,
    required this.controller,
    required this.onClose,
    this.onRevealOffset,
    this.showReplace = false,
  });

  @override
  State<FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<FindReplaceBar> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _replace = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  List<({int start, int end})> _matches = const [];
  int _current = -1;
  bool _caseSensitive = false;
  bool _regex = false;
  bool _invalidRegex = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onDocumentChanged);
    _query.addListener(_search);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queryFocus.requestFocus();
      _query.selection =
          TextSelection(baseOffset: 0, extentOffset: _query.text.length);
      _search();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onDocumentChanged);
    _query.removeListener(_search);
    _query.dispose();
    _replace.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onDocumentChanged() {
    // 文档被外部修改时保持当前匹配项（尽量不抢选择区）
    _search(keepCurrent: true);
  }

  void _search({bool keepCurrent = false}) {
    final text = widget.controller.text;
    final query = _query.text;
    final previous = keepCurrent && _current >= 0 && _current < _matches.length
        ? _matches[_current]
        : null;
    final matches = <({int start, int end})>[];
    _invalidRegex = false;

    if (query.isNotEmpty) {
      if (_regex) {
        try {
          final pattern = RegExp(query, caseSensitive: _caseSensitive);
          for (final match in pattern.allMatches(text)) {
            if (match.end > match.start) {
              matches.add((start: match.start, end: match.end));
            }
          }
        } on FormatException {
          _invalidRegex = true;
        }
      } else {
        final haystack = _caseSensitive ? text : text.toLowerCase();
        final needle = _caseSensitive ? query : query.toLowerCase();
        var index = haystack.indexOf(needle);
        while (index != -1) {
          matches.add((start: index, end: index + needle.length));
          index = haystack.indexOf(needle, index + needle.length);
        }
      }
    }

    var next = -1;
    if (matches.isNotEmpty) {
      if (previous != null) {
        final index = matches.indexWhere((m) => m.start == previous.start);
        next = index >= 0 ? index : 0;
      } else {
        final cursor = widget.controller.selection.baseOffset;
        final index = matches.indexWhere((m) => m.start >= cursor);
        next = index >= 0 ? index : 0;
      }
    }

    setState(() {
      _matches = matches;
      _current = next;
    });
    if (previous == null && next >= 0) {
      _selectCurrent();
    }
  }

  void _selectCurrent() {
    if (_current < 0 || _current >= _matches.length) return;
    final match = _matches[_current];
    widget.controller.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    widget.onRevealOffset?.call(match.start);
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + delta) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _selectCurrent();
  }

  void _replaceCurrent() {
    if (_current < 0 || _current >= _matches.length) return;
    final match = _matches[_current];
    final text = widget.controller.text;
    final replacement = _replace.text;
    final updated = text.replaceRange(match.start, match.end, replacement);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: match.start + replacement.length,
      ),
    );
    _search();
    _move(1);
  }

  void _replaceAll() {
    if (_matches.isEmpty) return;
    final text = widget.controller.text;
    final replacement = _replace.text;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in _matches) {
      buffer.write(text.substring(cursor, match.start));
      buffer.write(replacement);
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    widget.controller.value = TextEditingValue(
      text: buffer.toString(),
      selection: TextSelection.collapsed(offset: buffer.length),
    );
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF2D2D30) : const Color(0xFFF3F3F3);
    final borderColor = isDark ? const Color(0xFF3C3C3C) : const Color(0xFFDDDDDD);
    final countColor = _invalidRegex
        ? theme.colorScheme.error
        : (_matches.isEmpty ? theme.colorScheme.onSurfaceVariant : null);

    return Container(
      decoration: BoxDecoration(
        color: background,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  _field(
                    controller: _query,
                    focusNode: _queryFocus,
                    hint: '查找',
                    width: 220,
                    onSubmitted: (_) => _move(1),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    child: Text(
                      _invalidRegex
                          ? '正则无效'
                          : _matches.isEmpty
                              ? '无结果'
                              : '${_current + 1}/${_matches.length}',
                      style: TextStyle(fontSize: 11, color: countColor),
                    ),
                  ),
                  _iconButton(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: '上一个',
                    onPressed: () => _move(-1),
                  ),
                  _iconButton(
                    icon: Icons.keyboard_arrow_down,
                    tooltip: '下一个',
                    onPressed: () => _move(1),
                  ),
                  _toggle(
                    label: 'Aa',
                    tooltip: '区分大小写',
                    selected: _caseSensitive,
                    onPressed: () {
                      setState(() => _caseSensitive = !_caseSensitive);
                      _search();
                    },
                  ),
                  _toggle(
                    label: '.*',
                    tooltip: '正则表达式',
                    selected: _regex,
                    onPressed: () {
                      setState(() => _regex = !_regex);
                      _search();
                    },
                  ),
                  const Spacer(),
                  _iconButton(
                    icon: Icons.close,
                    tooltip: '关闭',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            if (widget.showReplace) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 30,
                child: Row(
                  children: [
                    _field(
                      controller: _replace,
                      hint: '替换为',
                      width: 220,
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _replaceCurrent,
                      child: const Text('替换', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: _replaceAll,
                      child:
                          const Text('全部替换', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required double width,
    FocusNode? focusNode,
    ValueChanged<String>? onSubmitted,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: width,
      height: 26,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onSubmitted: onSubmitted,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          filled: true,
          fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFCCCCCC),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFCCCCCC),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }

  Widget _toggle({
    required String label,
    required String tooltip,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 26,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
