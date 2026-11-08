import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../agent/mcp_tools.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/ai_change_journal.dart';
import '../services/llm_service.dart';
import 'settings_screen.dart';

/// AGC（AI Generated Code）模式主界面
///
/// 全屏 AI 对话体验（对标 Trae 移动端）：
/// - 空会话时展示欢迎语与建议问题
/// - 对话流中穿插工具调用卡片（流式输出 + Markdown 渲染）
/// - 底部常驻输入栏
///
/// 侧边栏菜单为「对话记录 / MCP·Skills」（见 [AgcHistoryPanel] / [AgcToolsPanel]）。
class AgcScreen extends StatefulWidget {
  const AgcScreen({super.key});

  @override
  State<AgcScreen> createState() => _AgcScreenState();
}

class _AgcScreenState extends State<AgcScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
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

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _inputController.text).trim();
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

    if (ai.isStreaming) {
      _scrollToBottom(animate: false);
    }

    final empty = ai.messages.isEmpty && !ai.isStreaming;

    return Column(
      children: [
        // 未配置 LLM 提示
        if (!settings.isLlmConfigured) _buildConfigBanner(isDark),

        // 对话区
        Expanded(
          child: empty
              ? _AgcWelcome(
                  isDark: isDark,
                  onSuggestion: (text) => _send(text),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  itemCount: ai.timeline.length + (ai.isStreaming ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= ai.timeline.length) {
                      return _AgcAiMessage(
                        content: ai.streamingText.isEmpty
                            ? t('ai.thinking')
                            : ai.streamingText,
                        isDark: isDark,
                        streaming: true,
                      );
                    }
                    final item = ai.timeline[index];
                    if (item is AgentToolStep) {
                      return _AgcToolCard(step: item, isDark: isDark);
                    }
                    final msg = item as ChatMessage;
                    if (msg.role == ChatRole.user) {
                      return _AgcUserMessage(
                        content: msg.content,
                        isDark: isDark,
                      );
                    }
                    return _AgcAiMessage(
                      content: msg.content,
                      isDark: isDark,
                      streaming: false,
                    );
                  },
                ),
        ),

        // 错误提示
        if (ai.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                ai.error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            ),
          ),

        // AI 改动待确认条
        const _AgcPendingBanner(),

        // 输入栏
        _AgcInputBar(
          controller: _inputController,
          busy: ai.isThinking,
          onSend: _send,
        ),
      ],
    );
  }

  Widget _buildConfigBanner(bool isDark) {
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: Colors.orange.withValues(alpha: 0.1),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t('ai.llmNotConfigured'),
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.orange.shade200 : Colors.orange.shade800,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: isDark ? Colors.orange.shade200 : Colors.orange.shade800,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 欢迎页
// =============================================================================

class _AgcWelcome extends StatelessWidget {
  const _AgcWelcome({required this.isDark, required this.onSuggestion});

  final bool isDark;
  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    (Icons.map_outlined, '介绍一下这个项目'),
    (Icons.add_circle_outline, '帮我写一个新的页面'),
    (Icons.bug_report_outlined, '帮我检查并修复问题'),
    (Icons.search, '在项目里搜索一段代码'),
  ];

  @override
  Widget build(BuildContext context) {
    final projectName = context
            .watch<ProjectProvider>()
            .projectPath
            ?.split(RegExp(r'[/\\]'))
            .last ??
        '';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF7C4DFF), Color(0xFF448AFF)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C4DFF).withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              projectName.isEmpty ? '有什么可以帮你的？' : '我是 $projectName 的 AI 搭档',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '可以直接让我读写项目文件、改代码、触发构建',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _suggestions
                  .map(
                    (s) => ActionChip(
                      avatar: Icon(s.$1, size: 15),
                      label: Text(s.$2, style: const TextStyle(fontSize: 12)),
                      onPressed: () => onSuggestion(s.$2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 消息气泡
// =============================================================================

/// 用户消息：右侧气泡
class _AgcUserMessage extends StatelessWidget {
  const _AgcUserMessage({required this.content, required this.isDark});

  final String content;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 56, bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF2D6CF6),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          content,
          style: const TextStyle(
            fontSize: 14,
            height: 1.5,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// AI 消息：全宽、无气泡边框（Trae 风格），Markdown 渲染
class _AgcAiMessage extends StatelessWidget {
  const _AgcAiMessage({
    required this.content,
    required this.isDark,
    required this.streaming,
  });

  final String content;
  final bool isDark;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF7C4DFF), Color(0xFF448AFF)],
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 12,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'SLIPE AI',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
              if (streaming) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          MarkdownBody(
            data: streaming ? '$content ▌' : content,
            selectable: true,
            styleSheet: _styleSheet(isDark),
            builders: {'pre': _AgcCodeBlockBuilder(isDark)},
          ),
        ],
      ),
    );
  }

  static MarkdownStyleSheet _styleSheet(bool isDark) {
    final textColor = isDark ? Colors.white : Colors.black87;
    return MarkdownStyleSheet(
      p: TextStyle(fontSize: 14, height: 1.6, color: textColor),
      h1: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.bold,
        color: textColor,
      ),
      h2: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: textColor,
      ),
      h3: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textColor,
      ),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        backgroundColor:
            isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F2F5),
        color: isDark ? const Color(0xFFCE9178) : const Color(0xFFB31D28),
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Color(0xFF7C4DFF), width: 3)),
      ),
      listBullet: TextStyle(fontSize: 14, color: textColor),
      a: const TextStyle(color: Color(0xFF448AFF)),
    );
  }
}

/// 代码块：横向滚动 + 复制按钮
class _AgcCodeBlockBuilder extends MarkdownElementBuilder {
  _AgcCodeBlockBuilder(this.isDark);

  final bool isDark;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return _AgcCodeBlock(code: element.textContent, isDark: isDark);
  }
}

class _AgcCodeBlock extends StatelessWidget {
  const _AgcCodeBlock({required this.code, required this.isDark});

  final String code;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final text = code.endsWith('\n') ? code : '$code\n';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t('ai.code'),
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
                    SnackBar(
                      content: Text(t('ai.codeCopied')),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 13),
                label: Text(t('ai.copy'), style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.45,
                color:
                    isDark ? const Color(0xFFD4D4D4) : const Color(0xFF1F2328),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具调用卡片（紧凑样式）
class _AgcToolCard extends StatefulWidget {
  const _AgcToolCard({required this.step, required this.isDark});

  final AgentToolStep step;
  final bool isDark;

  @override
  State<_AgcToolCard> createState() => _AgcToolCardState();
}

class _AgcToolCardState extends State<_AgcToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final isDark = widget.isDark;
    final color = step.running
        ? const Color(0xFF448AFF)
        : (step.failed ? Colors.orange : Colors.green);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: step.running
                ? null
                : () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  if (step.running)
                    const SizedBox(
                      width: 13,
                      height: 13,
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
                    child: Text(
                      step.summary.isEmpty ? step.tool : '${step.tool} · ${step.summary}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (step.running)
                    Text(
                      t('ai.executing'),
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
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  step.result.isEmpty ? t('ai.noResult') : step.result,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                    color: isDark
                        ? const Color(0xFFD4D4D4)
                        : const Color(0xFF1F2328),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// AI 改动待确认条
class _AgcPendingBanner extends StatelessWidget {
  const _AgcPendingBanner();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: AiChangeJournal.instance,
      builder: (context, _) {
        final count = AiChangeJournal.instance.pendingCount;
        if (count == 0) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          color: Colors.orange.withValues(alpha: 0.12),
          child: Row(
            children: [
              const Icon(Icons.pending_actions,
                  size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('ai.pendingChanges', {'count': '$count'}),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? Colors.orange.shade200
                        : Colors.orange.shade900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _showPendingDialog(context),
                child: Text(t('ai.view'), style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showPendingDialog(BuildContext context) async {
    final journal = AiChangeJournal.instance;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('ai.pendingTitle')),
        content: SizedBox(
          width: 560,
          child: ListenableBuilder(
            listenable: journal,
            builder: (context, _) {
              final pending = journal.pending;
              if (pending.isEmpty) {
                return Text(t('ai.noPending'));
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
                        child: Text(
                          t('ai.revert'),
                          style: const TextStyle(fontSize: 12),
                        ),
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
            child: Text(t('ai.revertAllDialog')),
          ),
          FilledButton(
            onPressed: () {
              journal.approveAll();
              Navigator.of(dialogContext).pop();
            },
            child: Text(t('ai.keepAll')),
          ),
        ],
      ),
    );
  }
}

/// 底部输入栏
class _AgcInputBar extends StatelessWidget {
  const _AgcInputBar({
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF26262B) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0xFFE0E4E8),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: 5,
                  minLines: 1,
                  keyboardType: TextInputType.multiline,
                  enabled: !busy,
                  decoration: InputDecoration(
                    hintText: busy ? t('ai.thinkingHint') : t('ai.inputHint'),
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white30 : Colors.black26,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF2D6CF6),
                    minimumSize: const Size(38, 38),
                  ),
                  onPressed: busy ? null : onSend,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_upward, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 侧边栏面板：对话记录
// =============================================================================

/// AGC 模式侧边栏「对话记录」面板
///
/// 展示当前会话的对话时间线（用户提问 / AI 回复摘要 / 工具调用），
/// 支持一键开启新对话。
class AgcHistoryPanel extends StatelessWidget {
  const AgcHistoryPanel({super.key, this.onClose});

  /// 点击条目后的回调（一般由编辑器用于收起侧边栏）
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final timeline = ai.timeline;

    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.history,
                size: 16,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${timeline.whereType<ChatMessage>().length} 条消息',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: ai.isThinking
                    ? null
                    : () {
                        ai.clear();
                        onClose?.call();
                      },
                icon: const Icon(Icons.add_comment_outlined, size: 14),
                label: const Text('新对话', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: timeline.isEmpty
              ? Center(
                  child: Text(
                    '暂无对话记录',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white30 : Colors.black26,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: timeline.length,
                  itemBuilder: (context, index) {
                    final item = timeline[index];
                    if (item is AgentToolStep) {
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.build_circle_outlined,
                          size: 16,
                          color: stepColor(item),
                        ),
                        title: Text(
                          item.summary.isEmpty ? item.tool : item.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        subtitle: Text(
                          item.tool,
                          style: const TextStyle(fontSize: 10),
                        ),
                        onTap: onClose,
                      );
                    }
                    final msg = item as ChatMessage;
                    final isUser = msg.role == ChatRole.user;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 16,
                        color: isUser
                            ? const Color(0xFF2D6CF6)
                            : const Color(0xFF7C4DFF),
                      ),
                      title: Text(
                        msg.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        isUser ? '我' : 'SLIPE AI',
                        style: const TextStyle(fontSize: 10),
                      ),
                      onTap: onClose,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Color stepColor(AgentToolStep step) => step.running
      ? const Color(0xFF448AFF)
      : (step.failed ? Colors.orange : Colors.green);
}

// =============================================================================
// 侧边栏面板：MCP / Skills
// =============================================================================

/// AGC 模式侧边栏「MCP/Skills」面板
///
/// 展示内置 Skill（系统提示词）与 Agent 可调用的全部 MCP 工具。
class AgcToolsPanel extends StatelessWidget {
  const AgcToolsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tools = ai.mcpTools;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionHeader(title: 'Skills', isDark: isDark),
        ListTile(
          dense: true,
          leading: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(
                colors: [Color(0xFF7C4DFF), Color(0xFF448AFF)],
              ),
            ),
            child: const Icon(
              Icons.psychology_outlined,
              size: 16,
              color: Colors.white,
            ),
          ),
          title: const Text('SLIPE Agent Skill', style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            '内置 Agent 工作规范与工具使用说明',
            style: TextStyle(fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showSkill(context),
        ),
        const SizedBox(height: 8),
        _SectionHeader(title: 'MCP 工具（${tools.length}）', isDark: isDark),
        ...tools.map(
          (tool) => ListTile(
            dense: true,
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              child: Icon(
                _toolIcon(tool.name),
                size: 15,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            title: Text(
              tool.name,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            subtitle: Text(
              tool.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }

  IconData _toolIcon(String name) {
    if (name.contains('read') || name.contains('get')) return Icons.visibility_outlined;
    if (name.contains('write') || name.contains('replace')) return Icons.edit_outlined;
    if (name.contains('create')) return Icons.note_add_outlined;
    if (name.contains('delete')) return Icons.delete_outline;
    if (name.contains('rename')) return Icons.drive_file_rename_outline;
    if (name.contains('list') || name.contains('search')) return Icons.search;
    if (name.contains('build')) return Icons.build_outlined;
    if (name.contains('terminal')) return Icons.terminal;
    return Icons.extension_outlined;
  }

  Future<void> _showSkill(BuildContext context) async {
    final content = await DefaultAssetBundle.of(
      context,
    ).loadString('assets/skills/skill.md');
    if (!context.mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SLIPE Agent Skill'),
        content: SizedBox(
          width: 560,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: content,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                  code: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.isDark});

  final String title;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: isDark ? Colors.white38 : Colors.black38,
        ),
      ),
    );
  }
}
