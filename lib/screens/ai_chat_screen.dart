import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../agent/mcp_tools.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/settings_provider.dart';
import '../services/ai_change_journal.dart';
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
                  itemCount: ai.timeline.length + (ai.isStreaming ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= ai.timeline.length) {
                      // 流式输出气泡
                      return _MessageBubble(
                        content: ai.streamingText.isEmpty
                            ? '思考中…'
                            : ai.streamingText,
                        isUser: false,
                        isDark: isDark,
                        streaming: true,
                      );
                    }
                    final item = ai.timeline[index];
                    if (item is AgentToolStep) {
                      // 工具调用及其返回结果，直接穿插在对话流中
                      return _ToolCallCard(step: item, isDark: isDark);
                    }
                    final msg = item as ChatMessage;
                    return _MessageBubble(
                      content: msg.content,
                      isUser: msg.role == ChatRole.user,
                      isDark: isDark,
                      streaming: false,
                    );
                  },
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

        // AI 改动待确认（默认已落盘，可随时撤回）
        _PendingChangesBanner(isDark: isDark),

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

/// AI 改动待确认条
///
/// AI 修改默认直接保存；这里汇总尚未确认的改动，
/// 用户可逐条撤回、全部撤回或全部保留。
class _PendingChangesBanner extends StatelessWidget {
  const _PendingChangesBanner({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AiChangeJournal.instance,
      builder: (context, _) {
        final count = AiChangeJournal.instance.pendingCount;
        if (count == 0) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          color: Colors.orange.withValues(alpha: 0.12),
          child: Row(
            children: [
              const Icon(Icons.pending_actions,
                  size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'AI 已修改 $count 个文件，尚未确认（未确认前不会推送到仓库）',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? Colors.orange.shade200
                        : Colors.orange.shade900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _showList(context),
                child: const Text('查看', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => _revertAll(context),
                child: const Text('撤回全部', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _revertAll(BuildContext context) async {
    final restored = await AiChangeJournal.instance.revertAllPending();
    if (restored == 0 || !context.mounted) return;
    await context.read<EditorProvider>().reloadAll();
  }

  Future<void> _showList(BuildContext context) async {
    final journal = AiChangeJournal.instance;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AI 修改待确认'),
        content: SizedBox(
          width: 560,
          child: ListenableBuilder(
            listenable: journal,
            builder: (context, _) {
              final pending = journal.pending;
              if (pending.isEmpty) {
                return const Text('没有待确认的修改');
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pending.length,
                  itemBuilder: (context, index) {
                    final entry = pending[index];
                    final name = entry.path.split(RegExp(r'[/\\]')).last;
                    return ListTile(
                      dense: true,
                      title: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: Text(
                        entry.action,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: TextButton(
                        onPressed: entry.reversible
                            ? () async {
                                final ok = await journal.revert(entry);
                                if (ok && dialogContext.mounted) {
                                  await dialogContext
                                      .read<EditorProvider>()
                                      .reloadAll();
                                }
                              }
                            : null,
                        child: const Text('撤回', style: TextStyle(fontSize: 12)),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final restored = await journal.revertAllPending();
              if (restored > 0 && dialogContext.mounted) {
                await dialogContext.read<EditorProvider>().reloadAll();
              }
            },
            child: const Text('全部撤回'),
          ),
          FilledButton(
            onPressed: () {
              journal.approveAll();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('全部保留'),
          ),
        ],
      ),
    );
  }
}

/// 对话流中的一次工具调用卡片
///
/// 展示工具名、参数摘要与实际返回结果，结果可折叠/展开。
class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({
    required this.step,
    required this.isDark,
  });

  final AgentToolStep step;
  final bool isDark;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final isDark = widget.isDark;
    final result = step.result;
    final color = step.running
        ? Colors.blueAccent
        : (step.failed ? Colors.orange : Colors.green);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232326) : const Color(0xFFF2F5F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (step.running)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      step.failed
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 15,
                      color: color,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.tool,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (step.summary.isNotEmpty)
                          Text(
                            step.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (step.running)
                    Text(
                      '执行中',
                      style: TextStyle(fontSize: 10, color: color),
                    )
                  else
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && !step.running)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1B1B1D) : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.isEmpty ? '（无返回内容）' : result,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                    color: isDark ? const Color(0xFFD4D4D4) : const Color(0xFF1F2328),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
