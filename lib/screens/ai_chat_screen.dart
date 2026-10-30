import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/ai_provider.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/llm_service.dart';
import 'settings_screen.dart';

/// AI 助手对话面板
///
/// 作为普通面板内嵌到编辑器侧边栏的「Agent」标签页。支持：
/// - 自然语言对话
/// - 把当前文件发给 AI 编辑
/// - Agent 通过 MCP 工具自动读写文件、创建 Dart 类、触发云端构建
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    await context.read<AiProvider>().sendMessage(text);
    _scrollToBottom();
  }

  /// 把当前文件附带指令一起发给 AI
  Future<void> _sendWithFile(String instruction) async {
    await context.read<AiProvider>().sendWithCurrentFile(instruction);
    _scrollToBottom();
  }

  /// 触发云端构建
  Future<void> _triggerBuild() async {
    final build = context.read<BuildProvider>();
    if (build.isRunning) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('构建已在进行中')));
      return;
    }
    // 侧边栏内嵌面板，无需关闭抽屉，直接启动构建
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未打开项目，无法构建')));
      return;
    }
    await build.startBuild(projectDir: projectPath);
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final settings = context.watch<SettingsProvider>().settings;
    final editor = context.watch<EditorProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                    '未配置 LLM。点击右上角设置填写 API 地址、Key 和模型。',
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

        // 快捷操作
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _QuickChip(
                icon: Icons.description,
                label: '解释当前文件',
                onTap: editor.hasActiveFile
                    ? () => _sendWithFile('请解释这个文件的代码逻辑')
                    : null,
              ),
              _QuickChip(
                icon: Icons.bug_report,
                label: '修复问题',
                onTap: editor.hasActiveFile
                    ? () => _sendWithFile('检查并修复这个文件中的问题，直接用工具修改文件')
                    : null,
              ),
              _QuickChip(
                icon: Icons.auto_fix_high,
                label: '优化代码',
                onTap: editor.hasActiveFile
                    ? () => _sendWithFile('优化这个文件的代码，直接用工具修改文件')
                    : null,
              ),
              _QuickChip(
                icon: Icons.cloud_upload,
                label: '云端构建',
                onTap: _triggerBuild,
              ),
            ],
          ),
        ),

        // 消息列表
        Expanded(
          child: ai.messages.isEmpty
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
                          '有什么可以帮你的？\n试试让我解释、修复或优化当前打开的文件。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
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
                  itemCount: ai.messages.length,
                  itemBuilder: (context, index) {
                    final msg = ai.messages[index];
                    return _MessageBubble(message: msg, isDark: isDark);
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

/// 单条消息气泡
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isDark});

  final ChatMessage message;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    if (message.role == ChatRole.system) {
      return const SizedBox.shrink();
    }
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
              Text(
                message.content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: isUser
                      ? Colors.white
                      : (isDark ? Colors.white : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快捷操作芯片
class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: onTap,
    );
  }
}
