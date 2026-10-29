import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/editor_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/volume_key_service.dart';
import '../widgets/ai_floating_ball.dart';
import '../widgets/app_background.dart';
import '../widgets/code_editor.dart';
import '../widgets/editor_tabs.dart';
import '../widgets/file_tree.dart';
import 'ai_chat_screen.dart';
import 'build_screen.dart';
import 'terminal_screen.dart';

/// 主编辑器界面
///
/// 左侧动效双面板侧边栏（文件 / Agent）+ 右侧标签页 + 编辑区 + 底部状态栏
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  bool _showSidebar = true;
  Timer? _autoSaveTimer;

  /// 侧边栏标签控制器（0=文件，1=Agent）
  late final TabController _sidebarTabController;

  /// 当前编辑器的 GlobalKey，用于音量键触发补全/Tab
  final GlobalKey<CodeEditorState> _codeEditorKey = GlobalKey<CodeEditorState>();

  @override
  void initState() {
    super.initState();
    _sidebarTabController = TabController(length: 2, vsync: this);
    // 如果已有项目路径但还没加载文件树
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final projectProvider = context.read<ProjectProvider>();
      if (projectProvider.projectPath != null &&
          projectProvider.fileTree == null) {
        projectProvider.refreshFileTree();
      }
    });
    _setupVolumeKeyHandler();
  }

  /// 音量上键 = 接受补全 / 插入 Tab（仅 Android；iOS 走虚拟按钮）
  void _setupVolumeKeyHandler() {
    if (!Platform.isAndroid) return;
    VolumeKeyService.instance.setHandler((keyCode) {
      // 仅处理音量上键；音量下键始终走系统默认
      if (keyCode != VolumeKeyService.keyVolumeUp) return false;
      final settings = context.read<SettingsProvider>().settings;
      if (!settings.completionEnabled) return false;

      final state = _codeEditorKey.currentState;
      if (state == null) return false;
      // 关闭「音量键补全」时，仅在有建议时接受，否则放行音量调节
      final fallback = settings.volumeKeyCompletionEnabled;
      return state.acceptSuggestionOrTab(fallbackToTab: fallback);
    });
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _sidebarTabController.dispose();
    // 离开编辑器时取消音量键拦截，恢复正常音量调节
    if (Platform.isAndroid) {
      VolumeKeyService.instance.setHandler(null);
    }
    super.dispose();
  }

  /// 自动保存（偏好设置开启时，停止输入 1 秒后写入并同步）
  void _scheduleAutoSave() {
    if (!context.read<SettingsProvider>().settings.autoSave) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 1), () async {
      final editorProvider = context.read<EditorProvider>();
      if (!mounted || !editorProvider.hasActiveFile) return;
      final path = editorProvider.activeFile!.path;
      final ok = await editorProvider.saveActiveFile();
      if (!mounted || !ok) return;
      context.read<GitSyncProvider>().markChanged(path);
    });
  }

  Future<void> _handleFileTap(String path) async {
    final editorProvider = context.read<EditorProvider>();
    final opened = await editorProvider.openFile(path);
    // 打开成功后自动收起侧边栏（方便小屏手机）
    if (opened != null && mounted) {
      setState(() => _showSidebar = false);
    }
  }

  /// 展开侧边栏并切换到 Agent 标签
  void _openAgentPanel() {
    setState(() => _showSidebar = true);
    _sidebarTabController.animateTo(1);
  }

  Future<void> _handleSave() async {
    final editorProvider = context.read<EditorProvider>();
    if (editorProvider.hasActiveFile) {
      final savedPath = editorProvider.activeFile!.path;
      final ok = await editorProvider.saveActiveFile();
      if (!mounted) return;
      if (ok) {
        // 标记变更，防抖后自动 push 到 GitHub（AI 自动同步）
        context.read<GitSyncProvider>().markChanged(savedPath);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '✓ 已保存' : '保存失败'),
          backgroundColor: ok ? Colors.green : Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  String _detectLanguage(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.dart')) return 'dart';
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'yaml';
    if (lower.endsWith('.json')) return 'json';
    if (lower.endsWith('.xml')) return 'xml';
    if (lower.endsWith('.gradle') || lower.endsWith('.kts')) return 'kotlin';
    if (lower.endsWith('.html')) return 'xml';
    if (lower.endsWith('.md')) return 'markdown';
    if (lower.endsWith('.kt')) return 'kotlin';
    if (lower.endsWith('.java')) return 'java';
    return 'plaintext';
  }

  @override
  Widget build(BuildContext context) {
    final projectProvider = context.watch<ProjectProvider>();
    final editorProvider = context.watch<EditorProvider>();
    final settings = context.watch<SettingsProvider>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          projectProvider.projectPath?.split(RegExp(r'[/\\]')).last ?? '编辑器',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: '终端 (proot)',
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const TerminalScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.build),
            tooltip: '构建',
            onPressed: () {
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const BuildScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'AI 助手（侧边栏 Agent）',
            onPressed: _openAgentPanel,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新文件树',
            onPressed: projectProvider.refreshFileTree,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存 (Ctrl+S)',
            onPressed: _handleSave,
          ),
          IconButton(
            icon: Icon(_showSidebar ? Icons.menu_open : Icons.menu),
            tooltip: '切换侧边栏',
            onPressed: () => setState(() => _showSidebar = !_showSidebar),
          ),
        ],
      ),
      // 编辑器界面始终按 IDE 规则叠加背景图（「仅编辑器」范围在此生效）
      body: AppBackground.wrap(
        isIdeScreen: true,
        child: Stack(
          children: [
            Row(
        children: [
          // 左侧动效双面板侧边栏（文件 / Agent）
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            width: _showSidebar ? 300 : 0,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: isDark
                      ? const Color(0xFF3C3C3C)
                      : const Color(0xFFE0E0E0),
                ),
              ),
              color: isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3),
            ),
            child: Column(
              children: [
                // 侧边栏标签栏：文件 / Agent
                SizedBox(
                  width: 300,
                  child: TabBar(
                    controller: _sidebarTabController,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: const [
                      Tab(text: '文件'),
                      Tab(text: 'Agent'),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 标签内容
                Expanded(
                  child: SizedBox(
                    width: 300,
                    child: TabBarView(
                      controller: _sidebarTabController,
                      children: [
                        // 文件管理器
                        FileTree(
                          root: projectProvider.fileTree,
                          isLoading: projectProvider.isLoading,
                          onFileTap: _handleFileTap,
                        ),
                        // Agent（AI 对话）
                        const AiChatScreen(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 右侧主编辑区
          Expanded(
            child: Column(
              children: [
                // 标签页栏
                const EditorTabs(),

                // 编辑区 / 欢迎提示
                Expanded(
                  child: editorProvider.hasActiveFile
                      ? _buildEditor(
                          editorProvider,
                          isDark,
                          settings.editorFontSize,
                          settings.completionEnabled,
                        )
                      : _buildWelcome(isDark),
                ),

                // 底部状态栏
                _buildStatusBar(editorProvider, isDark),
              ],
            ),
          ),
        ],
          ),

          // IDE 右下角 AI 悬浮球（偏好设置可关闭）
          if (settings.aiFloatingBallEnabled)
            AiFloatingBall(onTap: _openAgentPanel),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(
    EditorProvider editorProvider,
    bool isDark,
    double fontSize,
    bool completionEnabled,
  ) {
    final activeFile = editorProvider.activeFile!;
    final language = _detectLanguage(activeFile.path);
    // 语法补全仅对 Dart 文件启用
    final enableCompletion = completionEnabled && language == 'dart';

    return Column(
      children: [
        // 文件名 / 语言提示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          alignment: Alignment.centerRight,
          child: Text(
            '$language • ${activeFile.path}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ),
        Expanded(
          child: CodeEditor(
            key: _codeEditorKey,
            initialContent: activeFile.content,
            language: language,
            fontSize: fontSize,
            enableCompletion: enableCompletion,
            onChanged: (content) {
              editorProvider.updateActiveContent(content);
              _scheduleAutoSave();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWelcome(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.code,
            size: 64,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          const SizedBox(height: 16),
          Text(
            '从左侧文件树选择文件开始编辑',
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(EditorProvider editorProvider, bool isDark) {
    final activeFile = editorProvider.activeFile;
    final bgColor = isDark ? const Color(0xFF007ACC) : const Color(0xFF007ACC);

    return Container(
      height: 24,
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (activeFile != null) ...[
            Text(
              activeFile.isModified ? '● 已修改' : '● 已保存',
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
            const SizedBox(width: 20),
            Text(
              _detectLanguage(activeFile.path),
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
            const SizedBox(width: 20),
            Text(
              '${activeFile.content.split('\n').length} 行',
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
          ] else
            const Text(
              '就绪',
              style: TextStyle(fontSize: 11, color: Colors.white),
            ),
        ],
      ),
    );
  }
}
