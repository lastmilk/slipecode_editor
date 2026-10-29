import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
/// 侧边栏改为「浮层滑入」，不再挤压编辑区宽度；
/// 支持从左右边缘滑动唤出，打开文件后自动收起。
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  bool _showSidebar = false;
  Timer? _autoSaveTimer;

  /// 侧边栏标签控制器（0=文件，1=Agent）
  late final TabController _sidebarTabController;

  /// 当前编辑器状态，用于音量键驱动补全
  final GlobalKey<CodeEditorState> _codeEditorKey =
      GlobalKey<CodeEditorState>();

  /// 监听偏好设置变化，实时启停音量键拦截
  SettingsProvider? _settingsProvider;

  @override
  void initState() {
    super.initState();
    _sidebarTabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final projectProvider = context.read<ProjectProvider>();
      if (projectProvider.projectPath != null &&
          projectProvider.fileTree == null) {
        projectProvider.refreshFileTree();
      }
    });
    _settingsProvider = context.read<SettingsProvider>();
    _settingsProvider!.addListener(_syncVolumeKeyListener);
    _syncVolumeKeyListener();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _sidebarTabController.dispose();
    _settingsProvider?.removeListener(_syncVolumeKeyListener);
    // 离开编辑器时取消音量键拦截，恢复正常音量调节
    if (Platform.isAndroid) {
      VolumeKeyService.instance.setHandler(null);
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 音量键（Android）
  // ---------------------------------------------------------------------------

  /// 根据偏好设置启停音量键拦截
  ///
  /// 关闭「音量键补全」后必须注销原生监听，
  /// 否则音量键会被持续拦截、无法调节音量。
  void _syncVolumeKeyListener() {
    if (!Platform.isAndroid) return;
    final enabled =
        _settingsProvider?.settings.volumeKeyCompletionEnabled ?? false;
    VolumeKeyService.instance.setHandler(enabled ? _handleVolumeKey : null);
  }

  /// 编辑器内音量键永不调节音量：
  /// - 音量上键：确认当前补全候选（无候选时不做事）
  /// - 音量下键：有候选时切换下一个；无候选时唤出文件栏
  bool _handleVolumeKey(int keyCode) {
    if (!mounted) return false;
    final state = _codeEditorKey.currentState;
    if (keyCode == VolumeKeyService.keyVolumeUp) {
      state?.acceptSelected();
      return true; // 始终消费，避免触发音量控制
    }
    if (keyCode == VolumeKeyService.keyVolumeDown) {
      if (state != null && state.moveSelection()) return true;
      // 没有补全候选：唤出左侧文件栏
      setState(() => _showSidebar = true);
      _sidebarTabController.animateTo(0);
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

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
    // 打开成功后自动收起侧边栏（小屏手机可立刻看到代码）
    if (opened != null && mounted) {
      setState(() => _showSidebar = false);
    }
  }

  /// 展开侧边栏并切换到 Agent 标签
  void _openAgentPanel() {
    setState(() => _showSidebar = true);
    _sidebarTabController.animateTo(1);
  }

  void _toggleSidebar() {
    setState(() => _showSidebar = !_showSidebar);
  }

  Future<void> _handleSave() async {
    final editorProvider = context.read<EditorProvider>();
    if (!editorProvider.hasActiveFile) return;
    final savedPath = editorProvider.activeFile!.path;
    final ok = await editorProvider.saveActiveFile();
    if (!mounted) return;
    if (ok) {
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

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final projectProvider = context.watch<ProjectProvider>();
    final editorProvider = context.watch<EditorProvider>();
    final settings = context.watch<SettingsProvider>().settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final showBackground =
        AppBackground.shouldShow(settings, isIdeScreen: true);

    // 侧边栏宽度：窄屏最多占 82%，避免完全遮住代码
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth = math.min(300.0, screenWidth * 0.82);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          projectProvider.projectPath?.split(RegExp(r'[/\\]')).last ?? '编辑器',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: '终端 (proot)',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const TerminalScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.build),
            tooltip: '构建',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const BuildScreen())),
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
            onPressed: _toggleSidebar,
          ),
        ],
      ),
      body: AppBackground.wrap(
        isIdeScreen: true,
        child: Stack(
          children: [
            // 编辑区占满整个宽度（修复侧边栏挤压编辑器的问题）
            Column(
              children: [
                const EditorTabs(),
                Expanded(
                  child: editorProvider.hasActiveFile
                      ? _buildEditor(
                          editorProvider,
                          isDark,
                          settings.editorFontSize,
                          settings.completionEnabled,
                          showBackground,
                        )
                      : _buildWelcome(isDark),
                ),
                _buildStatusBar(editorProvider, isDark),
              ],
            ),

            // 侧边栏打开时的遮罩（点击关闭）
            if (_showSidebar)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _showSidebar = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.28)),
                ),
              ),

            // 侧边栏：浮层滑入，不占据编辑区宽度
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOutCubic,
              left: _showSidebar ? 0 : -sidebarWidth,
              top: 0,
              bottom: 0,
              width: sidebarWidth,
              child: _buildSidebar(
                projectProvider,
                isDark,
                sidebarWidth,
                translucent: showBackground,
              ),
            ),

            // 边缘滑动手势（侧边栏收起时可用）
            if (!_showSidebar) ...[
              _buildEdgeSwipe(Alignment.centerLeft, isRight: false),
              _buildEdgeSwipe(Alignment.centerRight, isRight: true),
            ],

            // AI 悬浮球
            if (settings.aiFloatingBallEnabled)
              AiFloatingBall(onTap: _openAgentPanel),
          ],
        ),
      ),
    );
  }

  /// 左右边缘手势条：向右滑（左边缘）/ 向左滑（右边缘）唤出文件栏
  Widget _buildEdgeSwipe(Alignment alignment, {required bool isRight}) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          final open = isRight ? velocity < -180 : velocity > 180;
          if (!open) return;
          setState(() => _showSidebar = true);
          _sidebarTabController.animateTo(0);
        },
        child: Container(
          width: 22,
          height: double.infinity,
          color: Colors.transparent,
        ),
      ),
    );
  }

  Widget _buildSidebar(
    ProjectProvider projectProvider,
    bool isDark,
    double width, {
    required bool translucent,
  }) {
    final panelColor = translucent
        ? (isDark
            ? const Color(0xF0202020)
            : const Color(0xF0FAFAFA))
        : (isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3));

    return Material(
      color: panelColor,
      elevation: 12,
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            TabBar(
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
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _sidebarTabController,
                children: [
                  FileTree(
                    root: projectProvider.fileTree,
                    isLoading: projectProvider.isLoading,
                    onFileTap: _handleFileTap,
                  ),
                  const AiChatScreen(),
                ],
              ),
            ),
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
    bool translucent,
  ) {
    final activeFile = editorProvider.activeFile!;
    final language = _detectLanguage(activeFile.path);
    final enableCompletion = completionEnabled && language == 'dart';

    return Column(
      children: [
        // 文件名 / 语言提示（透明，避免遮挡背景图）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          alignment: Alignment.centerRight,
          child: Text(
            '$language • ${activeFile.path}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
            translucent: translucent,
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
            '从左侧文件树选择文件开始编辑\n（左滑或右滑边缘可唤出文件栏）',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(EditorProvider editorProvider, bool isDark) {
    final activeFile = editorProvider.activeFile;

    return Container(
      height: 24,
      color: const Color(0xFF007ACC),
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
