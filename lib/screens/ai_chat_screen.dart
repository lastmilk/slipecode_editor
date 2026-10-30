import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../providers/ai_provider.dart';
import '../providers/settings_provider.dart';
import '../services/llm_service.dart';
import 'settings_screen.dart';

/// AI 助手对话面板
///
/// 作为普通面板内嵌到编辑器侧边栏的「Agent」标签页：
/// - 流式输出 + Markdown 渲染
/// - Agent 通过 MCP 工具自动读写文件、创建 Dart 类、触发云端构建
/// - 对话记录本地保存（可选同步云端）
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首次打开时加载本地记录（开启云同步则拉取云端）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AiProvider>().ensureCloudHistoryLoaded();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    await context.read<AiProvider>().sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final settings = context.watch<SettingsProvider>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 流式输出时保持滚动到底部
    if (ai.isStreaming) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }

    return Column(
      children: [
        // 标题栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF252526) : Colors.white,
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? const Color(0xFF3C3C3C)
                    : const Color(0xFFE0E0E0),
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome,
                color: Colors.blueAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'AI 助手',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.clear_all, size: 18),
                tooltip: '清空对话',
                onPressed: ai.clear,
              ),
              IconButton(
                icon: const Icon(Icons.settings, size: 18),
                tooltip: '配置 LLM',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
        ),

        // 配置提示
        if (!settings.isLlmConfigured)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.orange.withValues(alpha: 0.1),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '未配置 LLM。点击右上角设置添加模型（支持 OpenAI / DeepSeek / 通义等）。',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? Colors.orange.shade200
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 消息列表
        Expanded(
          child: ai.messages.isEmpty && !ai.isStreaming
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 48,
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '有什么可以帮你的？\nAgent 可以直接读写项目文件、创建 Dart 类并触发云端构建。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: ai.messages.length + (ai.isStreaming ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= ai.messages.length) {
                      return _MessageBubble(
                        content: ai.streamingText.isEmpty
                            ? '思考中…'
                            : ai.streamingText,
                        isUser: false,
                        isDark: isDark,
                        streaming: true,
                      );
                    }
                    final msg = ai.messages[index];
                    return _MessageBubble(
                      content: msg.content,
                      isUser: msg.role == ChatRole.user,
                      isDark: isDark,
                      streaming: false,
                    );
                  },
                ),
        ),

        // Agent 工具调用轨迹
        if (ai.steps.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.build_circle_outlined,
                      size: 14,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '工具调用（${ai.steps.length}）',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: ai.steps
                      .map(
                        (step) => Chip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(
                            '${step.tool} · ${step.summary}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),

        // 错误提示
        if (ai.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                ai.error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ),
          ),

        // 输入区
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? const Color(0xFF3C3C3C)
                    : const Color(0xFFE0E0E0),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: ai.isThinking ? 'AI 正在思考...' : '输入消息...',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  enabled: !ai.isThinking,
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: ai.isThinking ? null : _send,
                icon: ai.isThinking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单条消息气泡（AI 回复使用 Markdown 渲染）
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.content,
    required this.isUser,
    required this.isDark,
    required this.streaming,
  });

  final String content;
  final bool isUser;
  final bool isDark;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: 10,
        left: isUser ? 40 : 0,
        right: isUser ? 0 : 40,
      ),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isUser
                ? Colors.blueAccent
                : (isDark ? const Color(0xFF2D2D30) : Colors.white),
            borderRadius: BorderRadius.circular(10),
            border: isUser
                ? null
                : Border.all(
                    color: isDark
                        ? const Color(0xFF3C3C3C)
                        : const Color(0xFFE0E0E0),
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 12,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
              if (isUser)
                Text(
                  content,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Colors.white,
                  ),
                )
              else
                MarkdownBody(
                  data: streaming ? '$content ▌' : content,
                  selectable: true,
                  styleSheet: _styleSheet(isDark),
                  builders: {'pre': _CodeBlockBuilder(isDark)},
                ),
            ],
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _styleSheet(bool isDark) {
    final textColor = isDark ? Colors.white : Colors.black87;
    return MarkdownStyleSheet(
      p: TextStyle(fontSize: 13, height: 1.5, color: textColor),
      h1: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: textColor,
      ),
      h2: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: textColor,
      ),
      h3: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: textColor,
      ),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F2F5),
        color: isDark ? const Color(0xFFCE9178) : const Color(0xFFB31D28),
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      blockquoteDecoration: BoxDecoration(
        color: isDark ? const Color(0xFF232323) : const Color(0xFFF5F7FA),
        border: Border(left: BorderSide(color: Colors.blueAccent, width: 3)),
      ),
      listBullet: TextStyle(fontSize: 13, color: textColor),
      a: const TextStyle(color: Colors.blueAccent),
    );
  }
}

/// 代码块：横向滚动 + 复制按钮
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.isDark);

  final bool isDark;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return _CodeBlock(code: element.textContent, isDark: isDark);
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.isDark});

  final String code;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final text = code.endsWith('\n') ? code : '$code\n';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '代码',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制代码'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 13),
                label: const Text('复制', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
                color: isDark ? const Color(0xFFD4D4D4) : const Color(0xFF1F2328),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
