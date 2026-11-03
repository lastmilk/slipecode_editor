import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../agent/mcp_tools.dart';
import '../models/project.dart';
import '../providers/ai_provider.dart';
import '../providers/project_provider.dart';
import '../services/app_globals.dart';
import '../services/llm_service.dart';
import '../services/project_history_service.dart';

/// 轻量 AI 对话悬浮窗
///
/// 不跳转页面：点击悬浮球后直接在底部弹出对话窗。
/// 对话框下部可以选择要操作的项目，输入需求后 AI 会在该项目中自动执行。
class AiQuickChatSheet extends StatefulWidget {
  const AiQuickChatSheet({
    super.key,
    this.initialPrompt,
    this.initialProjectPath,
  });

  /// 系统悬浮球面板中已输入的需求（打开后自动执行）
  final String? initialPrompt;

  /// 系统悬浮球面板中选择的项目
  final String? initialProjectPath;

  static bool _visible = false;

  /// 从任意页面弹出（Editor 内悬浮球 / 系统悬浮球点击均可复用）
  static Future<void> show(
    BuildContext context, {
    String? prompt,
    String? projectPath,
  }) async {
    if (_visible) return;
    _visible = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => AiQuickChatSheet(
          initialPrompt: prompt,
          initialProjectPath: projectPath,
        ),
      );
    } finally {
      _visible = false;
    }
  }

  /// 系统悬浮球没有 Widget 上下文，通过全局 Navigator 打开
  static Future<void> showFromGlobal({
    String? prompt,
    String? projectPath,
  }) async {
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    await show(context, prompt: prompt, projectPath: projectPath);
  }

  @override
  State<AiQuickChatSheet> createState() => _AiQuickChatSheetState();
}

class _AiQuickChatSheetState extends State<AiQuickChatSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<Project> _projects = [];
  String? _selectedPath;
  bool _loading = true;
  bool _autoSendScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProjects();
      context.read<AiProvider>().ensureCloudHistoryLoaded();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    final currentWorkspace = context.read<ProjectProvider>().projectPath;
    final history = await ProjectHistoryService.instance.list();
    final current = widget.initialProjectPath ?? currentWorkspace;
    final items = <Project>[...history];
    if (current != null && !items.any((e) => e.path == current)) {
      items.insert(
        0,
        Project(
          name: p.basename(current),
          path: current,
          createdAt: DateTime.now(),
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _projects
        ..clear()
        ..addAll(items);
      _selectedPath = current ?? (items.isEmpty ? null : items.first.path);
      _loading = false;
    });

    // 系统悬浮球面板已输入需求：打开对话框后直接开始执行
    final prompt = widget.initialPrompt?.trim();
    if (prompt != null && prompt.isNotEmpty && !_autoSendScheduled) {
      _autoSendScheduled = true;
      _input.text = prompt;
      WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final ai = context.read<AiProvider>();
    if (text.isEmpty || ai.isStreaming || ai.isThinking) return;

    final project = context.read<ProjectProvider>();
    final path = _selectedPath;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在首页创建或导入项目')),
      );
      return;
    }

    _input.clear();
    // AI 在所选项目中执行：先切换工作区，再交给 Agent
    if (project.projectPath != path) {
      await project.openProject(path);
    }
    await ai.sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final available = media.size.height - media.viewInsets.bottom;
    final height = math.min(media.size.height * 0.62, available - 24);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        height: math.max(260.0, height),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('SLIPE AI', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _buildTimeline(ai, theme),
          ),
          if (ai.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                ai.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          const Divider(height: 1),
          _buildComposer(theme, ai),
        ],
        ),
      ),
    );
  }

  Widget _buildTimeline(AiProvider ai, ThemeData theme) {
    final items = ai.timeline;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '选择下方项目并输入需求，AI 会直接在该项目中执行',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    const maxItems = 30;
    final shown =
        items.length > maxItems ? items.sublist(items.length - maxItems) : items;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      itemCount: shown.length + (ai.streamingText.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= shown.length) {
          return _bubble(
            theme,
            role: ChatRole.assistant,
            text: ai.streamingText,
            streaming: true,
          );
        }
        final item = shown[index];
        if (item is AgentToolStep) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  item.running ? Icons.pending_outlined : Icons.check_circle,
                  size: 14,
                  color: item.running
                      ? theme.colorScheme.primary
                      : Colors.green,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${item.tool} · ${item.summary}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }
        if (item is ChatMessage) {
          return _bubble(theme, role: item.role, text: item.content);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _bubble(
    ThemeData theme, {
    required ChatRole role,
    required String text,
    bool streaming = false,
  }) {
    final isUser = role == ChatRole.user;
    final color = isUser
        ? theme.colorScheme.primary.withValues(alpha: 0.12)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          streaming ? '$text▍' : text,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }

  Widget _buildComposer(ThemeData theme, AiProvider ai) {
    final busy = ai.isStreaming || ai.isThinking;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 要操作的项目
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('加载项目…'),
                        )
                      : DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedPath,
                            hint: const Text('选择项目'),
                            items: [
                              for (final project in _projects)
                                DropdownMenuItem(
                                  value: project.path,
                                  child: Text(
                                    project.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (value) =>
                                    setState(() => _selectedPath = value),
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !busy,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: '输入需求，例如「为首页添加搜索框」',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: busy ? null : _send,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                tooltip: '执行',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
