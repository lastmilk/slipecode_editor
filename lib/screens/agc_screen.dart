import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../agent/mcp_tools.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_segment.dart';
import '../providers/account_provider.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../services/ai_change_journal.dart';
import '../services/ai_attachment_service.dart';
import '../services/ai_extensions_service.dart';
import '../services/conversation_service.dart';
import '../services/llm_service.dart';
import '../widgets/llm_model_bar.dart';
import '../widgets/mcp_edit_dialog.dart';
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

  /// 输入以「/」开头时为指令匹配关键字（不含 '/'），否则为 null
  String? _slashQuery;

  /// 待发送的图片附件
  final List<ChatImageAttachment> _pendingImages = [];

  /// 待发送的文本附件
  final List<AiTextAttachment> _pendingFiles = [];

  @override
  void initState() {
    super.initState();
    _inputController.addListener(_onInputChanged);
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

  void _onInputChanged() {
    final text = _inputController.text;
    final query =
        text.startsWith('/') && !text.contains(' ') && !text.contains('\n')
        ? text.substring(1)
        : null;
    if (query != _slashQuery) setState(() => _slashQuery = query);
  }

  /// 执行选中的「/」指令
  void _runSlashCommand(String command) {
    _inputController.clear();
    switch (command) {
      case '/plan':
        context.read<AiProvider>().setPlanMode(true);
        break;
    }
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
    if (text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) {
      return;
    }
    // 直接发送「/」指令时同样生效（如用户未点选面板，直接输入 /plan 回车）
    if (text == '/plan') {
      _runSlashCommand(text);
      return;
    }
    final images = List<ChatImageAttachment>.from(_pendingImages);
    final files = List<AiTextAttachment>.from(_pendingFiles);
    final attachmentContext = AiAttachmentService.composeContext(files);
    final attachmentNames = [
      ...images.map((e) => e.name),
      ...files.map((e) => e.name),
    ];
    _inputController.clear();
    setState(() {
      _pendingImages.clear();
      _pendingFiles.clear();
    });
    await context.read<AiProvider>().sendMessage(
      text.isEmpty ? '请分析我上传的附件' : text,
      images: images,
      attachmentContext: attachmentContext,
      attachmentNames: attachmentNames,
    );
    _scrollToBottom();
  }

  /// 选择附件类型（图片 / 文件）
  Future<void> _showAttachmentSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final image = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF26262B) : Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('上传图片'),
              subtitle: const Text('需要当前模型支持图片理解'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('上传文件'),
              subtitle: const Text('文本文件直接读取，Zip 会解压后读取文本'),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    if (image == null || !mounted) return;
    if (image) {
      await _pickImages();
    } else {
      await _pickFiles();
    }
  }

  /// 选择图片附件
  Future<void> _pickImages() async {
    final ai = context.read<AiProvider>();
    if (!ai.currentModelSupportsVision) {
      _showSnack('当前模型不支持图片理解，请在设置中切换到支持图片的模型');
      return;
    }
    final account = context.read<AccountProvider>();
    await AiAttachmentService.instance.ensureLimits(token: account.token);
    final result = await AiAttachmentService.instance.pickImages();
    if (!mounted) return;
    if (result.images.isNotEmpty) {
      setState(() => _pendingImages.addAll(result.images));
    }
    if (result.skipped.isNotEmpty) {
      _showSnack('部分图片未添加：${result.skipped.join('；')}');
    }
  }

  /// 选择文件附件
  Future<void> _pickFiles() async {
    final account = context.read<AccountProvider>();
    await AiAttachmentService.instance.ensureLimits(token: account.token);
    final result = await AiAttachmentService.instance.pickFiles(
      token: account.token,
    );
    if (!mounted) return;
    if (result.files.isNotEmpty) {
      setState(() => _pendingFiles.addAll(result.files));
    }
    if (result.skipped.isNotEmpty) {
      _showSnack('部分文件未添加：${result.skipped.take(3).join('；')}');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (ai.isStreaming) {
      _scrollToBottom(animate: false);
    }

    final empty = ai.messages.isEmpty && !ai.isStreaming;

    // 工具调用已聚合进消息的渲染分段，时间线只展示对话消息
    final items = ai.timeline.whereType<ChatMessage>().toList();

    return Column(
      children: [
        // 未配置 LLM 提示（内置模型可用时不会提示）
        if (!ai.isConfigured) _buildConfigBanner(isDark),

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
                  itemCount: items.length + (ai.isStreaming ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= items.length) {
                      return _AgcAiMessage(
                        content: ai.streamingText.isEmpty
                            ? t('ai.thinking')
                            : ai.streamingText,
                        isDark: isDark,
                        streaming: true,
                        reasoning: ai.streamingReasoning.isEmpty
                            ? null
                            : ai.streamingReasoning,
                        segments: ai.streamSegments,
                      );
                    }
                    final msg = items[index];
                    if (msg.role == ChatRole.user) {
                      return _AgcUserMessage(
                        content: msg.content,
                        isDark: isDark,
                      );
                    }
                    final isLast =
                        index == items.length - 1 && !ai.isStreaming;
                    return _AgcAiMessage(
                      content: msg.content,
                      isDark: isDark,
                      streaming: false,
                      reasoning: msg.reasoning,
                      segments: msg.segments,
                      showPlanAction:
                          msg.kind == 'plan' && isLast && !ai.isThinking,
                      onExecutePlan: () => ai.executePlan(),
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

        // 计划模式提示条（/plan 指令开启）
        if (ai.planMode) _buildPlanChip(isDark),

        // 模型与积分栏
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
          child: LlmModelBar(isDark: isDark),
        ),

        // 「/」指令面板
        if (_slashQuery != null && !ai.isThinking)
          _SlashCommandPanel(
            query: _slashQuery!,
            isDark: isDark,
            onSelect: _runSlashCommand,
          ),

        // 已选附件
        if (_pendingImages.isNotEmpty || _pendingFiles.isNotEmpty)
          _buildAttachmentChips(),

        // 输入栏
        _AgcInputBar(
          controller: _inputController,
          busy: ai.isThinking,
          onSend: _send,
          onAttach: ai.isThinking ? null : _showAttachmentSheet,
        ),
      ],
    );
  }

  /// 待发送附件列表（可逐个移除）
  Widget _buildAttachmentChips() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _pendingImages.length; i++)
            InputChip(
              avatar: const Icon(Icons.image_outlined, size: 14),
              label: Text(
                _pendingImages[i].name,
                style: const TextStyle(fontSize: 11),
              ),
              visualDensity: VisualDensity.compact,
              onDeleted: () => setState(() => _pendingImages.removeAt(i)),
            ),
          for (var i = 0; i < _pendingFiles.length; i++)
            InputChip(
              avatar: const Icon(Icons.description_outlined, size: 14),
              label: Text(
                _pendingFiles[i].name,
                style: const TextStyle(fontSize: 11),
              ),
              visualDensity: VisualDensity.compact,
              onDeleted: () => setState(() => _pendingFiles.removeAt(i)),
            ),
        ],
      ),
    );
  }

  /// 计划模式提示条：提醒用户 AI 只会制定计划，确认后才执行
  Widget _buildPlanChip(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 5, 6, 5),
      color: const Color(0xFF7C4DFF).withValues(alpha: 0.10),
      child: Row(
        children: [
          const Icon(
            Icons.format_list_numbered,
            size: 15,
            color: Color(0xFF7C4DFF),
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '计划模式：AI 会先制定实施计划，确认后再执行',
              style: TextStyle(fontSize: 11, color: Color(0xFF7C4DFF)),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            onPressed: () => context.read<AiProvider>().setPlanMode(false),
            icon: const Icon(Icons.close, color: Color(0xFF7C4DFF)),
          ),
        ],
      ),
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
///
/// 当 [segments] 非空时按真实时间顺序分段渲染
/// （思考过程折叠块 / 工具调用聚合卡片 / 正文穿插）。
class _AgcAiMessage extends StatelessWidget {
  const _AgcAiMessage({
    required this.content,
    required this.isDark,
    required this.streaming,
    this.reasoning,
    this.segments,
    this.showPlanAction = false,
    this.onExecutePlan,
  });

  final String content;
  final bool isDark;
  final bool streaming;

  /// AI 思考过程（reasoning_content，无分段时的旧渲染路径）
  final String? reasoning;

  /// 按时间顺序排列的渲染分段（思考 / 工具批次 / 正文）
  final List<ChatSegment>? segments;

  /// 是否为计划消息且等待用户确认执行
  final bool showPlanAction;

  /// 用户点击「执行计划」
  final VoidCallback? onExecutePlan;

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
          if (segments != null && segments!.isNotEmpty)
            ..._buildSegments()
          else ...[
            if (reasoning != null && reasoning!.isNotEmpty)
              _AgcThinkingBlock(
                text: reasoning!,
                isDark: isDark,
                streaming: streaming,
              ),
            MarkdownBody(
              data: streaming ? '$content ▌' : content,
              selectable: true,
              styleSheet: _styleSheet(isDark),
              builders: {'pre': _AgcCodeBlockBuilder(isDark)},
            ),
          ],
          if (showPlanAction)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2D6CF6),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onExecutePlan,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text(
                  '执行计划',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 按时间顺序渲染分段：思考折叠块 / 工具批次卡片 / 正文 Markdown
  List<Widget> _buildSegments() {
    final list = segments!;
    final widgets = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      final seg = list[i];
      final isLast = i == list.length - 1;
      switch (seg.kind) {
        case ChatSegmentKind.reasoning:
          widgets.add(
            _AgcThinkingBlock(
              text: seg.text,
              isDark: isDark,
              streaming: streaming && isLast,
            ),
          );
        case ChatSegmentKind.tools:
          widgets.add(
            _AgcToolBatchCard(steps: seg.steps, isDark: isDark),
          );
        case ChatSegmentKind.text:
          final text = seg.text;
          if (text.isEmpty && !(streaming && isLast)) break;
          widgets.add(
            MarkdownBody(
              data: streaming && isLast ? '$text ▌' : text,
              selectable: true,
              styleSheet: _styleSheet(isDark),
              builders: {'pre': _AgcCodeBlockBuilder(isDark)},
            ),
          );
      }
    }
    return widgets;
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

/// AI 思考过程：流式时自动展开，结束后可折叠查看
class _AgcThinkingBlock extends StatefulWidget {
  const _AgcThinkingBlock({
    required this.text,
    required this.isDark,
    required this.streaming,
  });

  final String text;
  final bool isDark;
  final bool streaming;

  @override
  State<_AgcThinkingBlock> createState() => _AgcThinkingBlockState();
}

class _AgcThinkingBlockState extends State<_AgcThinkingBlock> {
  late bool _expanded = widget.streaming;

  @override
  void didUpdateWidget(covariant _AgcThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streaming && !widget.streaming) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final hintColor = isDark ? Colors.white54 : Colors.black45;

    // Trae 风格：无边框的「思考过程 ›」低调行，展开后显示思考正文
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined, size: 14, color: hintColor),
                  const SizedBox(width: 5),
                  Text(
                    widget.streaming ? '思考中…' : '思考过程',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: hintColor,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: hintColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 19, top: 2, bottom: 4),
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ),
        ],
      ),
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

/// 工具调用聚合卡片（Trae 风格）
///
/// 连续多个工具调用聚合为一个可折叠卡片，
/// 标题按工具类型归纳：执行 N 条命令 / 读取 N 个文件 / 搜索 N 次 / 调用 N 个工具。
class _AgcToolBatchCard extends StatefulWidget {
  const _AgcToolBatchCard({required this.steps, required this.isDark});

  final List<AgentToolStep> steps;
  final bool isDark;

  @override
  State<_AgcToolBatchCard> createState() => _AgcToolBatchCardState();
}

class _AgcToolBatchCardState extends State<_AgcToolBatchCard> {
  bool _expanded = false;

  /// 按步骤中的工具名归纳批次标题
  String get _label {
    final steps = widget.steps;
    final n = steps.length;
    bool all(bool Function(String) test) =>
        steps.every((s) => test(s.tool.toLowerCase()));
    if (all((t) => t.contains('terminal') || t.contains('shell'))) {
      return '执行 $n 条命令';
    }
    if (all((t) => t.contains('read') || t.contains('get'))) {
      return '读取 $n 个文件';
    }
    if (all((t) =>
        t.contains('search') || t.contains('list') || t.contains('grep'))) {
      return '搜索 $n 次';
    }
    if (all((t) =>
        t.contains('write') ||
        t.contains('create') ||
        t.contains('replace') ||
        t.contains('edit'))) {
      return '修改 $n 个文件';
    }
    return '调用 $n 个工具';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final running = widget.steps.any((s) => s.running);
    final hintColor = isDark ? Colors.white54 : Colors.black45;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (running)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    Icon(Icons.build_outlined, size: 14, color: hintColor),
                  const SizedBox(width: 5),
                  Text(
                    _label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: hintColor,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: hintColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 19, top: 2, bottom: 4),
              child: Column(
                children: widget.steps
                    .map((s) => _AgcToolCard(step: s, isDark: isDark))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「/」指令面板：输入 '/' 时弹出，按前缀过滤，点选执行
class _SlashCommandPanel extends StatelessWidget {
  const _SlashCommandPanel({
    required this.query,
    required this.isDark,
    required this.onSelect,
  });

  /// 指令匹配关键字（不含 '/'）
  final String query;
  final bool isDark;
  final ValueChanged<String> onSelect;

  /// 已支持的指令（后续可扩展）
  static const _commands = [
    (
      '/plan',
      '计划模式',
      'AI 先制定实施计划，确认后再执行',
      Icons.format_list_numbered,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final matched = _commands
        .where((c) => c.$1.startsWith('/$query'))
        .toList();
    if (matched.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF26262B) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : const Color(0xFFE0E4E8),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: matched
            .map(
              (c) => ListTile(
                dense: true,
                leading: Icon(c.$4, size: 17, color: const Color(0xFF7C4DFF)),
                title: Text(
                  '${c.$1} · ${c.$2}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(c.$3, style: const TextStyle(fontSize: 11)),
                onTap: () => onSelect(c.$1),
              ),
            )
            .toList(),
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
    this.onAttach,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  /// 选择附件（图片 / 文件）；为 null 时隐藏入口
  final VoidCallback? onAttach;

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
              if (onAttach != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: busy ? null : onAttach,
                    icon: const Icon(Icons.attach_file, size: 19),
                    tooltip: '上传图片或文件',
                  ),
                ),
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

/// AGC 模式侧边栏「对话记录」面板（DeepSeek 风格会话列表）
///
/// - 顶部搜索框（按标题与消息内容过滤）
/// - 「置顶」折叠分组 + 按时间分组（今天 / 昨天 / 7 天内 / 更早）
/// - 长按条目：置顶 / 重命名 / 删除
/// - 底部用户栏（登录邮箱；未登录提示仅本地保存）
class AgcHistoryPanel extends StatefulWidget {
  const AgcHistoryPanel({super.key, this.onClose});

  /// 点击会话条目后的回调（一般由编辑器用于收起侧边栏）
  final VoidCallback? onClose;

  @override
  State<AgcHistoryPanel> createState() => _AgcHistoryPanelState();
}

class _AgcHistoryPanelState extends State<AgcHistoryPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _pinnedExpanded = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 时间分组：0=今天 1=昨天 2=7天内 3=更早
  int _groupOf(int updatedAt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime.fromMillisecondsSinceEpoch(updatedAt);
    final diff = today.difference(DateTime(day.year, day.month, day.day)).inDays;
    if (diff <= 0) return 0;
    if (diff == 1) return 1;
    if (diff < 7) return 2;
    return 3;
  }

  static const _groupTitles = ['今天', '昨天', '7 天内', '更早'];

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: ai.conversations,
      builder: (context, _) {
        final service = ai.conversations;
        final query = _query.trim().toLowerCase();
        final all = service.conversations.where((c) {
          if (query.isEmpty) return true;
          if (c.title.toLowerCase().contains(query)) return true;
          return c.messages.any(
            (m) => m.content.toLowerCase().contains(query),
          );
        }).toList();
        final pinned = all.where((c) => c.pinned).toList();
        final unpinned = all.where((c) => !c.pinned).toList();

        return Column(
          children: [
            // 搜索框
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索对话内容…',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white30 : Colors.black26,
                  ),
                  prefixIcon: const Icon(Icons.search, size: 17),
                  isDense: true,
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),

            // 开启新对话
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: ai.isThinking
                      ? null
                      : () {
                          ai.startNewSession();
                          widget.onClose?.call();
                        },
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('开启新对话', style: TextStyle(fontSize: 12)),
                ),
              ),
            ),

            // 会话列表
            Expanded(
              child: all.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty ? '暂无对话记录' : '没有匹配的对话',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white30 : Colors.black26,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        if (pinned.isNotEmpty) ...[
                          _buildPinnedHeader(isDark),
                          if (_pinnedExpanded)
                            ...pinned.map((c) => _buildTile(c, service, isDark)),
                          const Divider(height: 16),
                        ],
                        for (var g = 0; g < 4; g++)
                          ..._buildGroup(g, unpinned, service, isDark),
                      ],
                    ),
            ),

            // 底部用户栏
            _buildUserBar(account, isDark),
          ],
        );
      },
    );
  }

  /// 「置顶」可折叠分组头
  Widget _buildPinnedHeader(bool isDark) {
    return InkWell(
      onTap: () => setState(() => _pinnedExpanded = !_pinnedExpanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
        child: Row(
          children: [
            Text(
              '置顶',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              _pinnedExpanded ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建某个时间分组（组头 + 组内会话条目）
  List<Widget> _buildGroup(
    int group,
    List<AiConversation> unpinned,
    ConversationService service,
    bool isDark,
  ) {
    final items = unpinned.where((c) => _groupOf(c.updatedAt) == group).toList();
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
        child: Text(
          _groupTitles[group],
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ),
      ...items.map((c) => _buildTile(c, service, isDark)),
    ];
  }

  /// 单个会话条目：选中高亮，长按弹出操作菜单
  Widget _buildTile(
    AiConversation conv,
    ConversationService service,
    bool isDark,
  ) {
    final selected = service.currentId == conv.id;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: const Color(0xFF2D6CF6).withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conv.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (!conv.synced)
            Icon(
              Icons.cloud_off_outlined,
              size: 13,
              color: isDark ? Colors.white24 : Colors.black26,
            ),
        ],
      ),
      onTap: () {
        context.read<AiProvider>().openSession(conv.id);
        widget.onClose?.call();
      },
      onLongPress: () => _showSessionActions(conv, service),
    );
  }

  /// 长按会话：置顶 / 重命名 / 删除
  void _showSessionActions(AiConversation conv, ConversationService service) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: Icon(
                conv.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                size: 18,
              ),
              title: Text(conv.pinned ? '取消置顶' : '置顶'),
              onTap: () {
                service.togglePin(conv.id);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 18),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _renameSession(conv, service);
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
              title: Text('删除', style: TextStyle(color: Colors.red.shade400)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.read<AiProvider>().deleteSession(conv.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 重命名会话对话框
  Future<void> _renameSession(
    AiConversation conv,
    ConversationService service,
  ) async {
    final controller = TextEditingController(text: conv.title);
    final renamed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名对话', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入新的对话名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    if (renamed != null && renamed.trim().isNotEmpty) {
      service.rename(conv.id, renamed.trim());
    }
  }

  /// 底部用户栏：头像 + 邮箱；未登录提示仅本地保存
  Widget _buildUserBar(AccountProvider account, bool isDark) {
    final user = account.user;
    final subtitle = user == null
        ? '未登录 · 会话仅保存在本机'
        : (user.email.isNotEmpty ? user.email : user.displayName);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: isDark ? Colors.white12 : Colors.black12),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor:
                isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08),
            child: Icon(
              Icons.person_outline,
              size: 15,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    final ext = AiExtensionsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tools = ai.mcpTools;

    return ListenableBuilder(
      listenable: ext,
      builder: (context, _) {
        final servers = ext.servers;
        final skills = ext.skills;
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
              title: const Text(
                'SLIPE Agent Skill',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                '内置 Agent 工作规范与工具使用说明',
                style: TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _showSkill(context),
            ),
            const SizedBox(height: 8),
            _SectionHeader(
              title: '导入的 Skills（${skills.length}）',
              isDark: isDark,
            ),
            if (skills.isEmpty)
              _emptyHint('未导入外部 Skill，可在设置中导入')
            else
              ...skills.map(
                (skill) => ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.auto_stories_outlined,
                    size: 18,
                    color: skill.enabled
                        ? (isDark ? Colors.white70 : Colors.black54)
                        : (isDark ? Colors.white24 : Colors.black26),
                  ),
                  title: Text(
                    skill.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: skill.enabled ? null : Colors.grey,
                    ),
                  ),
                  subtitle: Text(
                    skill.enabled ? '已启用' : '已停用',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add_circle_outline, size: 18),
              title: const Text('导入 / 管理 Skill', style: TextStyle(fontSize: 12)),
              onTap: () => _openSettings(context),
            ),
            const SizedBox(height: 8),
            _SectionHeader(
              title: '第三方 MCP（${servers.length}）',
              isDark: isDark,
            ),
            if (servers.isEmpty)
              _emptyHint('未配置第三方 MCP，可直接添加或粘贴配置导入')
            else
              ...servers.map(
                (server) => ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.dns_outlined,
                    size: 18,
                    color: server.enabled
                        ? (isDark ? Colors.white70 : Colors.black54)
                        : (isDark ? Colors.white24 : Colors.black26),
                  ),
                  title: Text(
                    server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: server.enabled ? null : Colors.grey,
                    ),
                  ),
                  subtitle: Text(
                    '${server.transport.toUpperCase()} · ${server.endpointLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 16),
                  onTap: () async {
                    final ai = context.read<AiProvider>();
                    await showMcpServerEditor(context, existing: server);
                    await ai.refreshMcpTools();
                  },
                ),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add_circle_outline, size: 18),
              title: const Text('添加 MCP 服务器', style: TextStyle(fontSize: 12)),
              subtitle: const Text(
                '支持 HTTP / SSE / stdio 三种传输方式',
                style: TextStyle(fontSize: 10),
              ),
              onTap: () async {
                final ai = context.read<AiProvider>();
                await showMcpServerEditor(context);
                await ai.refreshMcpTools();
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.content_paste_outlined, size: 18),
              title: const Text('粘贴 JSON 配置导入', style: TextStyle(fontSize: 12)),
              subtitle: const Text(
                '支持 Claude / Trae / Cursor 格式',
                style: TextStyle(fontSize: 10),
              ),
              onTap: () async {
                final ai = context.read<AiProvider>();
                await showMcpConfigImport(context);
                await ai.refreshMcpTools();
              },
            ),
            const SizedBox(height: 8),
            _SectionHeader(
              title: 'MCP 工具（${tools.length}）',
              isDark: isDark,
            ),
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
      },
    );
  }

  Widget _emptyHint(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
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
