import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/file_node.dart';
import '../models/open_file.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/dart_class_template.dart';
import '../services/file_service.dart';
import '../services/volume_key_service.dart';
import '../widgets/ai_floating_ball.dart';
import '../widgets/app_background.dart';
import '../widgets/code_editor.dart';
import '../widgets/editor_tabs.dart';
import '../widgets/file_tree.dart';
import '../widgets/symbol_keypad.dart';
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

  /// 已确认退出（避免 PopScope 重复拦截）
  bool _allowPop = false;

  /// 侧边栏标签控制器（0=文件，1=Agent）
  late final TabController _sidebarTabController;

  /// 当前编辑器状态，用于音量键驱动补全
  final GlobalKey<CodeEditorState> _codeEditorKey =
      GlobalKey<CodeEditorState>();

  final FileService _fileService = FileService();

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
    // 不再自动保存：仅关闭标签 / 主动保存 / 退出确认时落盘
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

  /// 立即把所有未保存文件写盘（仅在用户明确选择「保存并退出 / 保存」时调用）
  Future<void> _saveAllNow() async {
    try {
      final editorProvider = context.read<EditorProvider>();
      final gitSync = context.read<GitSyncProvider>();
      final modified = List<OpenFile>.from(
        editorProvider.openFiles.where((file) => file.isModified),
      );
      for (final file in modified) {
        if (await editorProvider.saveFile(file.path)) {
          gitSync.markChanged(file.path);
        }
      }
    } catch (e) {
      debugPrint('保存未落盘改动失败：$e');
    }
  }

  /// 退出编辑器前的未保存确认
  Future<bool> _confirmExit() async {
    final editorProvider = context.read<EditorProvider>();
    if (!editorProvider.hasUnsavedChanges) return true;
    final count =
        editorProvider.openFiles.where((file) => file.isModified).length;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('editor.unsavedTitle')),
        content: Text(t('editor.unsavedBody', {'count': '$count'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text(t('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text(t('editor.discard')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Text(t('editor.saveAndExit')),
          ),
        ],
      ),
    );
    if (action == 'save') {
      await _saveAllNow();
      return true;
    }
    return action == 'discard';
  }

  /// 关闭标签：有未保存修改时先确认
  Future<void> _handleCloseTab(OpenFile file) async {
    final editorProvider = context.read<EditorProvider>();
    if (!file.isModified) {
      editorProvider.closeFile(file.path);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('editor.closeFileTitle', {'name': file.name})),
        content: Text(t('editor.closeFileBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text(t('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text(t('editor.discard')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Text(t('common.save')),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == 'cancel') return;
    if (action == 'save') {
      final ok = await editorProvider.saveFile(file.path);
      if (!mounted || !ok) return;
      context.read<GitSyncProvider>().markChanged(file.path);
    }
    editorProvider.closeFile(file.path);
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
        content: Text(ok ? t('editor.savedOk') : t('editor.saveFailed')),
        backgroundColor: ok ? Colors.green : Colors.red,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _detectLanguage(String path) {
    final payload = context.read<ProjectProvider>().payload;
    return payload.languageFor(path);
  }

  // ---------------------------------------------------------------------------
  // 文件管理
  // ---------------------------------------------------------------------------

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<String?> _promptName({
    required String title,
    required String hint,
    String initial = '',
    String? helper,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint, helperText: helper),
          onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _refreshTree() async {
    if (!mounted) return;
    await context.read<ProjectProvider>().refreshFileTree();
  }

  Future<void> _createFileDialog(String dirPath) async {
    final name = await _promptName(
      title: t('editor.newFile'),
      hint: 'example.dart',
      helper: t('editor.anyExtension'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final file = await _fileService.createFile(dirPath, name);
      await _refreshTree();
      await _handleFileTap(file.path);
    } catch (e) {
      _snack(t('editor.createFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _createDirDialog(String parentPath) async {
    final name = await _promptName(
      title: t('editor.newFolder'),
      hint: 'lib',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await _fileService.createDirectory(parentPath, name);
      await _refreshTree();
    } catch (e) {
      _snack(t('editor.createFailed', {'error': '$e'}), error: true);
    }
  }

  Future<DartClassKind?> _pickDartClassKind() async {
    return showDialog<DartClassKind>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t('editor.pickDartTemplate')),
        children: DartClassKind.values
            .map(
              (kind) => SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(kind),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(kind.label),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _createDartClassDialog(String dirPath) async {
    final name = await _promptName(
      title: t('editor.newDartClass'),
      hint: 'MyWidget',
      helper: t('editor.dtoHelper'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final kind = await _pickDartClassKind();
    if (kind == null || !mounted) return;
    try {
      final fileName = DartClassTemplate.fileNameFor(name);
      final content = DartClassTemplate.generate(kind, name);
      final file = await _fileService.createFile(
        dirPath,
        fileName,
        content: content,
      );
      await _refreshTree();
      await _handleFileTap(file.path);
    } catch (e) {
      _snack(t('editor.createFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _renameNode(FileNode node) async {
    final editor = context.read<EditorProvider>();
    final newName = await _promptName(
      title: t('editor.rename'),
      hint: node.name,
      initial: node.name,
    );
    if (newName == null || newName.isEmpty || !mounted) return;
    if (newName == node.name) return;
    try {
      final newPath = await _fileService.renameEntity(node.path, newName);
      if (node.isDirectory) {
        editor.renameDirectory(node.path, newPath);
      } else {
        editor.renameOpenFile(node.path, newPath);
      }
      await _refreshTree();
      _snack(t('editor.renamed', {'name': newName}));
    } catch (e) {
      _snack(t('editor.renameFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _deleteNode(FileNode node) async {
    final editor = context.read<EditorProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('editor.deleteTitle')),
        content: Text(
          node.isDirectory
              ? t('editor.deleteDirBody', {'name': node.name})
              : t('editor.deleteFileBody', {'name': node.name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('editor.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _fileService.deleteEntity(node.path);
      editor.closeFilesUnder(node.path);
      await _refreshTree();
      _snack(t('editor.deleted', {'name': node.name}));
    } catch (e) {
      _snack(t('editor.deleteFailed', {'error': '$e'}), error: true);
    }
  }

  /// 长按文件 / 文件夹：弹出操作菜单
  Future<void> _showNodeMenu(FileNode node) async {
    final payload = context.read<ProjectProvider>().payload;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  node.isDirectory ? Icons.folder : Icons.insert_drive_file,
                  color: Colors.amber,
                ),
                title: Text(node.name),
                subtitle: Text(
                  node.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                dense: true,
              ),
              Divider(
                height: 1,
                color: isDark ? Colors.white12 : Colors.black12,
              ),
              if (node.isDirectory) ...[
                ListTile(
                  leading: const Icon(Icons.note_add),
                  title: Text(t('editor.newFile')),
                  onTap: () => Navigator.of(ctx).pop('newFile'),
                ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder),
                  title: Text(t('editor.newFolder')),
                  onTap: () => Navigator.of(ctx).pop('newFolder'),
                ),
                if (payload.isFlutter)
                  ListTile(
                    leading: const Icon(Icons.widgets),
                    title: Text(t('editor.newDartClass')),
                    subtitle: Text(t('editor.dtoHelper')),
                    onTap: () => Navigator.of(ctx).pop('newDartClass'),
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(t('editor.rename')),
                onTap: () => Navigator.of(ctx).pop('rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text(
                  t('editor.delete'),
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;

    final dirPath = node.isDirectory ? node.path : p.dirname(node.path);
    switch (action) {
      case 'newFile':
        await _createFileDialog(dirPath);
      case 'newFolder':
        await _createDirDialog(dirPath);
      case 'newDartClass':
        await _createDartClassDialog(dirPath);
      case 'rename':
        await _renameNode(node);
      case 'delete':
        await _deleteNode(node);
    }
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

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final ok = await _confirmExit();
        if (!ok || !mounted) return;
        setState(() => _allowPop = true);
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
        title: Text(
          projectProvider.projectPath?.split(RegExp(r'[/\\]')).last ??
              t('editor.title'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: t('editor.terminal'),
            onPressed: () => showTerminalSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.build),
            tooltip: t('editor.build'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const BuildScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: t('editor.ai'),
            onPressed: _openAgentPanel,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('editor.refresh'),
            onPressed: projectProvider.refreshFileTree,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: t('editor.save'),
            onPressed: _handleSave,
          ),
          IconButton(
            icon: Icon(_showSidebar ? Icons.menu_open : Icons.menu),
            tooltip: t('editor.sidebar'),
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
                EditorTabs(onRequestClose: _handleCloseTab),
                Expanded(
                  child: editorProvider.hasActiveFile
                      ? _buildEditor(
                          editorProvider,
                          isDark,
                          settings.editorFontSize,
                          settings.fontFamily,
                          settings.completionEnabled,
                          showBackground,
                        )
                      : _buildWelcome(isDark),
                ),
                if (editorProvider.hasActiveFile)
                  SymbolKeypad(
                    isDark: isDark,
                    onInsert: (symbol) =>
                        _codeEditorKey.currentState?.insertAtCursor(symbol),
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
              tabs: [
                Tab(text: t('editor.files')),
                const Tab(text: 'Agent'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _sidebarTabController,
                children: [
                  _buildFilePanel(projectProvider, isDark),
                  const AiChatScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件面板：顶部操作栏 + 文件树（长按可重命名 / 删除）
  Widget _buildFilePanel(ProjectProvider projectProvider, bool isDark) {
    final payload = projectProvider.payload;
    final rootPath = projectProvider.projectPath;

    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.note_add, size: 18),
                tooltip: t('editor.newFile'),
                onPressed: rootPath == null ? null : () => _createFileDialog(rootPath),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.create_new_folder, size: 18),
                tooltip: t('editor.newFolder'),
                onPressed: rootPath == null ? null : () => _createDirDialog(rootPath),
              ),
              if (payload.isFlutter)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.widgets, size: 18),
                  tooltip: t('editor.newDartClass'),
                  onPressed:
                      rootPath == null ? null : () => _createDartClassDialog(rootPath),
                ),
              const Spacer(),
              Text(
                payload.name,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: t('editor.refresh'),
                onPressed: projectProvider.refreshFileTree,
              ),
            ],
          ),
        ),
        Expanded(
          child: FileTree(
            root: projectProvider.fileTree,
            isLoading: projectProvider.isLoading,
            onFileTap: _handleFileTap,
            onLongPress: _showNodeMenu,
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(
    EditorProvider editorProvider,
    bool isDark,
    double fontSize,
    String fontFamily,
    bool completionEnabled,
    bool translucent,
  ) {
    final activeFile = editorProvider.activeFile!;
    final language = _detectLanguage(activeFile.path);
    final enableCompletion = completionEnabled && language == 'dart';
    final ai = context.watch<AiProvider>();
    final vibeBusy = ai.vibeBusy;

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
          child: Stack(
            children: [
              // VibeCoding 执行期间锁定编辑区，把空间留给 AI
              AbsorbPointer(
                absorbing: vibeBusy,
                child: CodeEditor(
                  key: _codeEditorKey,
                  initialContent: activeFile.content,
                  language: language,
                  fontSize: fontSize,
                  fontFamily: fontFamily,
                  enableCompletion: enableCompletion,
                  translucent: translucent,
                  readOnly: vibeBusy,
                  onVibeRequest: (requirement, lineStart, lineEnd) {
                    ai.runVibeCoding(
                      filePath: activeFile.path,
                      requirement: requirement,
                      lineStart: lineStart,
                      lineEnd: lineEnd,
                    );
                  },
                  onChanged: (content) {
                    editorProvider.updateActiveContent(content);
                  },
                ),
              ),
              if (vibeBusy) _buildVibeOverlay(ai, isDark),
            ],
          ),
        ),
      ],
    );
  }

  /// VibeCoding 进行中的遮罩：提示 + 思考片段 + 取消
  Widget _buildVibeOverlay(AiProvider ai, bool isDark) {
    final thinking = ai.vibeThinking.trim();
    return Positioned(
      left: 8,
      right: 8,
      top: 8,
      child: Material(
        color: isDark ? const Color(0xF0202020) : const Color(0xF0FFFFFF),
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t('editor.aiEditing'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: ai.cancelVibe,
                    child: Text(
                      t('common.cancel'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (thinking.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: Text(
                    thinking,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
            t('editor.welcome'),
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
              activeFile.isModified ? t('editor.modified') : t('editor.saved'),
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
            const SizedBox(width: 20),
            Text(
              _detectLanguage(activeFile.path),
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
            const SizedBox(width: 20),
            Text(
              t('editor.lines', {'count': '${activeFile.content.split('\n').length}'}),
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
          ] else
            Text(
              t('editor.ready'),
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
        ],
      ),
    );
  }
}
