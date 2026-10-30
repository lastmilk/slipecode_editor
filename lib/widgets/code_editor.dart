import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/completion_service.dart';
import '../services/llm_service.dart';
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

  /// 是否启用补全建议
  final bool enableCompletion;

  /// 是否使用半透明背景（背景图模式下为 true）
  final bool translucent;

  const CodeEditor({
    super.key,
    this.initialContent = '',
    this.language = 'dart',
    this.onChanged,
    this.readOnly = false,
    this.fontSize = 14,
    this.enableCompletion = true,
    this.translucent = false,
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

  // VibeCoding：输入 `..需求` / `。。需求` 后自动调用远端 LLM 并插入代码
  Timer? _vibeTimer;
  Timer? _vibeMessageTimer;
  bool _vibeBusy = false;
  String? _vibeMessage;
  String? _lastVibeKey;

  @override
  void initState() {
    super.initState();
    _colors = SyntaxColors.of(isDark: false);
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
    _vibeTimer?.cancel();
    _vibeMessageTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _suggestionScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // VibeCoding
  // ---------------------------------------------------------------------------

  /// 解析光标前的 `..需求` / `。。需求` 触发词
  _VibeRequest? _detectVibeRequest() {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    if (cursor <= 0 || cursor > text.length) return null;

    final lineStart = text.lastIndexOf('\n', cursor - 1) + 1;
    final line = text.substring(lineStart, cursor).trimRight();
    final match = RegExp(r'^(.*?)(?:\.\.|。。)(.+)$').firstMatch(line);
    if (match == null) return null;

    // 只识别「行首（缩进后）以 .. 开头」的写法，避免误判 Dart 级联操作符（如 list..add(1)）
    final indent = match.group(1)!;
    if (indent.trim().isNotEmpty) return null;

    final requirement = match.group(3)!.trim();
    if (requirement.isEmpty) return null;

    return _VibeRequest(
      start: lineStart + indent.length,
      end: cursor,
      requirement: requirement,
      indent: indent,
      trigger: text.substring(lineStart + indent.length, cursor),
    );
  }

  void _scheduleVibeCoding() {
    if (widget.readOnly) return;
    _vibeTimer?.cancel();
    if (_vibeBusy) return;

    final request = _detectVibeRequest();
    if (request == null) {
      _lastVibeKey = null;
      return;
    }
    final key = '${request.start}:${request.requirement}';
    if (key == _lastVibeKey) return;
    _vibeTimer = Timer(const Duration(milliseconds: 700), () {
      _runVibeCoding(request, key);
    });
  }

  void _showVibeMessage(String? message, {bool autoClear = true}) {
    _vibeMessageTimer?.cancel();
    setState(() => _vibeMessage = message);
    if (message != null && autoClear) {
      _vibeMessageTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _vibeMessage = null);
      });
    }
  }

  Future<void> _runVibeCoding(_VibeRequest request, String key) async {
    if (!mounted || _vibeBusy) return;
    final settings = context.read<SettingsProvider>().settings;
    if (!settings.isLlmConfigured) {
      _lastVibeKey = key;
      _showVibeMessage('未配置 LLM：请在「偏好设置 → AI 助手」填写 API 地址 / Key / 模型');
      return;
    }

    final sourceText = _controller.text;
    if (!sourceText.contains(request.trigger)) return;

    setState(() {
      _vibeBusy = true;
      _vibeMessage = 'VibeCoding 生成中…';
    });

    final before = sourceText.substring(0, request.start);
    final after = sourceText.substring(request.end);
    final prefix = before.length > 4000
        ? before.substring(before.length - 4000)
        : before;
    final suffix = after.length > 1500 ? after.substring(0, 1500) : after;

    try {
      final reply = await LlmService.instance.chat(
        apiBase: settings.llmApiBase,
        apiKey: settings.llmApiKey,
        model: settings.llmModel,
        messages: [
          ChatMessage(
            role: ChatRole.system,
            content: '你是 SLIPE 编辑器内置的 VibeCoding 代码生成器。'
                '当前高亮语言：${widget.language}。'
                '只输出需要插入的代码，不要解释，不要使用 Markdown 代码围栏。'
                '代码要能直接粘贴到光标位置并保持可编译。',
          ),
          ChatMessage(
            role: ChatRole.user,
            content: '需求：${request.requirement}\n\n'
                '当前文件（<CURSOR> 标记需要插入代码的位置）：\n'
                '$prefix<CURSOR>$suffix',
          ),
        ],
      );

      if (!mounted) return;

      // 生成期间文本若已变化，放弃本次结果，避免插入到错误位置
      final current = _controller.text;
      if (request.end > current.length ||
          current.substring(request.start, request.end) != request.trigger) {
        setState(() => _vibeBusy = false);
        _showVibeMessage('文本已变化，本次 VibeCoding 结果已丢弃');
        return;
      }

      var code = _unwrapCode(reply);
      if (code.trim().isEmpty) {
        setState(() => _vibeBusy = false);
        _showVibeMessage('LLM 没有返回可插入的代码');
        return;
      }

      // 保持原有缩进：第一行沿用当前缩进，后续行补齐
      final lines = code.split('\n');
      if (request.indent.isNotEmpty) {
        for (var i = 1; i < lines.length; i++) {
          if (lines[i].trim().isEmpty) {
            lines[i] = '';
          } else {
            lines[i] = '${request.indent}${lines[i]}';
          }
        }
      }
      code = lines.join('\n');

      final newText = current.replaceRange(request.start, request.end, code);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: request.start + code.length,
        ),
      );
      widget.onChanged?.call(newText);
      _lastVibeKey = key;
      setState(() => _vibeBusy = false);
      _showVibeMessage('✓ VibeCoding 已插入 ${lines.length} 行代码');
    } catch (e) {
      if (!mounted) return;
      setState(() => _vibeBusy = false);
      _showVibeMessage('VibeCoding 失败：$e');
    }
  }

  /// 去掉 Markdown 代码围栏，只保留代码
  String _unwrapCode(String reply) {
    final fence = RegExp(r'```[\w-]*\n([\s\S]*?)```');
    final match = fence.firstMatch(reply);
    if (match != null) return match.group(1)!.trimRight();
    return reply.trimRight();
  }

  // ---------------------------------------------------------------------------
  // 补全逻辑
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    _scheduleVibeCoding();
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
          if (_vibeBusy || _vibeMessage != null) _buildVibeBar(isDark),
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
                fontFamily: 'monospace',
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

  /// VibeCoding 状态条（生成中 / 结果提示）
  Widget _buildVibeBar(bool isDark) {
    final busy = _vibeBusy;
    return Container(
      width: double.infinity,
      color: busy
          ? Colors.blueAccent.withValues(alpha: 0.14)
          : Colors.orange.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          if (busy)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.auto_awesome, size: 14, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _vibeMessage ?? '',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
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
                              fontFamily: 'monospace',
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

/// VibeCoding 触发请求
class _VibeRequest {
  /// 触发词起点（`..` / `。。` 的位置）
  final int start;

  /// 触发词终点（光标位置）
  final int end;

  /// 用户需求
  final String requirement;

  /// 触发词所在行的缩进（`..` 之前的文本）
  final String indent;

  /// 插入前的原始触发文本（用于校验位置未变化）
  final String trigger;

  const _VibeRequest({
    required this.start,
    required this.end,
    required this.requirement,
    required this.indent,
    required this.trigger,
  });
}

