import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../agent/design_agent_service.dart';
import '../agent/design_tools.dart';
import '../models/design_draft.dart';
import '../providers/ai_provider.dart';
import '../services/llm_service.dart';

/// 设计稿 AI 对话页
///
/// 使用独立的设计稿 MCP（DesignToolkit）编排当前设计稿，
/// 与代码编辑器的 Agent 工具集互不影响。
class DesignAiScreen extends StatefulWidget {
  const DesignAiScreen({
    super.key,
    required this.draft,
    required this.onChanged,
    this.onSaved,
  });

  final DesignDraft draft;
  final VoidCallback onChanged;
  final VoidCallback? onSaved;

  @override
  State<DesignAiScreen> createState() => _DesignAiScreenState();
}

class _DesignAiScreenState extends State<DesignAiScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<_DesignChatItem> _items = [];
  bool _busy = false;
  bool _cancelRequested = false;
  String _streaming = '';

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final ai = context.read<AiProvider>();
    await ai.ensureBuiltinModels();
    final target = ai.llmTarget;
    if (target == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置 AI 模型')),
      );
      return;
    }
    _input.clear();
    final history = <ChatMessage>[
      for (final item in _items)
        if (item.role != _DesignChatRole.step)
          ChatMessage(
            role: item.role == _DesignChatRole.user
                ? ChatRole.user
                : ChatRole.assistant,
            content: item.text,
          ),
      ChatMessage(role: ChatRole.user, content: text),
    ];
    setState(() {
      _items.add(_DesignChatItem(_DesignChatRole.user, text));
      _busy = true;
      _cancelRequested = false;
      _streaming = '';
    });
    _scrollToBottom();

    final toolkit = DesignToolkit(
      draft: widget.draft,
      onChanged: () {
        widget.onChanged();
        widget.onSaved?.call();
      },
    );
    final service = DesignAgentService(toolkit);
    String reply;
    try {
      reply = await service.run(
        apiBase: target.apiBase,
        apiKey: target.apiKey,
        model: target.model,
        history: history,
        isCancelled: () => _cancelRequested,
        onDelta: (delta) {
          if (!mounted) return;
          setState(() => _streaming += delta);
          _scrollToBottom();
        },
        onStep: (name, summary) {
          if (!mounted) return;
          setState(() {
            _items.add(_DesignChatItem(
              _DesignChatRole.step,
              '$name · $summary',
            ));
          });
        },
      );
    } catch (e) {
      reply = '执行失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _items.add(_DesignChatItem(_DesignChatRole.assistant, reply));
      _busy = false;
      _streaming = '';
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设计稿 AI'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                widget.draft.name,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _items.isEmpty && !_busy
                ? _buildWelcome(isDark)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    itemCount: _items.length + (_busy ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _items.length) {
                        return _buildStreaming(isDark);
                      }
                      final item = _items[index];
                      if (item.role == _DesignChatRole.step) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Icon(Icons.build_circle_outlined,
                                  size: 13,
                                  color: isDark
                                      ? Colors.white38
                                      : Colors.black45),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  item.text,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontFamily: 'monospace',
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.black45,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return _buildBubble(item, isDark);
                    },
                  ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              8,
              8 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              border: Border(
                top: BorderSide(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '描述你想要的设计稿，例如：做一个带登录/控制台/设置三个端的后台',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white30 : Colors.black26,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _busy
                      ? () => setState(() => _cancelRequested = true)
                      : _send,
                  icon: Icon(_busy ? Icons.stop : Icons.arrow_upward),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcome(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.design_services_outlined,
                size: 52, color: Colors.teal),
            const SizedBox(height: 12),
            Text(
              '用一句话生成设计稿',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'AI 会自动选择 Root、创建端、挂载模块并连线，'
              '你可以随时继续补充要求。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreaming(bool isDark) {
    final text = _streaming.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome, size: 15, color: Colors.purple),
          const SizedBox(width: 8),
          Expanded(
            child: text.isEmpty
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : MarkdownBody(
                    data: text,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(_DesignChatItem item, bool isDark) {
    final isUser = item.role == _DesignChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? const Color(0xFF0175C2)
              : (isDark ? const Color(0xFF26262B) : const Color(0xFFF2F4F7)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: isUser
            ? Text(
                item.text,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              )
            : MarkdownBody(
                data: item.text,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12.5,
                    height: 1.65,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
      ),
    );
  }
}

enum _DesignChatRole { user, assistant, step }

class _DesignChatItem {
  _DesignChatItem(this.role, this.text);

  final _DesignChatRole role;
  final String text;
}
