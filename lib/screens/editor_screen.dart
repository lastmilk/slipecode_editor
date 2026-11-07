import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/file_node.dart';
import '../models/open_file.dart';
import '../payloads/loader/loader_project_payload.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/ai_change_journal.dart';
import '../services/dart_class_template.dart';
import '../services/file_service.dart';
import '../services/volume_key_service.dart';
import '../widgets/ai_floating_ball.dart';
import '../widgets/ai_quick_chat.dart';
import '../widgets/app_background.dart';
import '../widgets/code_editor.dart';
import '../widgets/editor_tabs.dart';
import '../widgets/file_tree.dart';
import '../widgets/symbol_keypad.dart';
import 'agc_screen.dart';
import 'ai_chat_screen.dart';
import 'build_screen.dart';
import 'loader_build_screen.dart';
import 'terminal_screen.dart';

/// 编辑器形态
///
/// - [cde]：传统 IDE 形态（代码编辑为主），菜单栏为「文件 / Agent」
/// - [agc]：AI 对话形态（AI 生成为主），菜单栏为「对话记录 / MCP·Skills」
enum EditorMode { cde, agc }

/// 主编辑器界面
///
/// 支持 CDE / AGC 双形态：
/// - 传统项目默认 CDE，右滑进入 AGC，左滑切回 CDE；
/// - Loader 项目默认 AGC，右滑进入 CDE，左滑切回 AGC（两者相反）。
///
/// 侧边栏为浮层滑入，不挤压编辑区宽度；菜单栏随形态切换。
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

  /// 当前编辑器形态（首次 build 时按项目载荷确定默认值）
  EditorMode? _mode;

  /// 侧边栏标签控制器：
  /// CDE 模式 0=文件，1=Agent；AGC 模式 0=对话记录，1=MCP/Skills
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
      // 没有补全候选：唤出左侧文件栏（仅 CDE 模式）
      if (_mode == EditorMode.cde) {
        setState(() => _showSidebar = true);
        _sidebarTabController.animateTo(0);
      }
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
    if (editorProvider.hasUnsavedChanges) {
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
      } else if (action != 'discard') {
        return false;
      }
    }
    return _confirmAiChanges();
  }

  /// 退出前提醒用户确认 AI 改动
  ///
  /// 未确认的改动不会被推送到 GitHub / Gitee（由 AiChangeJournal 拦截）。
  Future<bool> _confirmAiChanges() async {
    final journal = AiChangeJournal.instance;
    if (!journal.hasPending) return true;
    final pending = journal.pending;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 修改待确认'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI 本次修改了 ${pending.length} 个文件，尚未确认。\n'
                '未确认的修改不会推送到 GitHub / Gitee。',
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    pending
                        .map((entry) =>
                            '${entry.action}  ${entry.path.split(RegExp(r'[/\\\\]')).last}')
                        .join('\n'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('revert'),
            child: const Text('撤回全部'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('later'),
            child: const Text('稍后处理'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('approve'),
            child: const Text('保留全部'),
          ),
        ],
      ),
    );
    if (action == 'approve') {
      journal.approveAll();
      return true;
    }
    if (action == 'revert') {
      await journal.revertAllPending();
      if (mounted) await context.read<EditorProvider>().reloadAll();
      return true;
    }
    // 稍后处理：保留待确认记录，推送时会被拦截
    return true;
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

  // ---------------------------------------------------------------------------
  // CDE / AGC 形态切换
  // ---------------------------------------------------------------------------

  /// 当前项目类型的默认形态：Loader 项目默认 AGC，传统项目默认 CDE
  EditorMode _defaultMode(ProjectProvider projectProvider) {
    return projectProvider.payload.id == LoaderProjectPayload.payloadId
        ? EditorMode.agc
        : EditorMode.cde;
  }

  /// 切换形态（同时收起侧边栏，避免菜单栏内容错位）
  void _switchMode(EditorMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _showSidebar = false;
    });
  }

  /// 水平滑动切换形态，两种项目方向相反：
  /// - 右滑：传统项目 → AGC，Loader 项目 → CDE
  /// - 左滑：传统项目 → CDE，Loader 项目 → AGC
  void _handleModeSwipe(double velocity) {
    const threshold = 300.0;
    if (_showSidebar) return; // 侧边栏打开时不响应形态切换
    final defaultMode = _defaultMode(context.read<ProjectProvider>());
    if (velocity > threshold) {
      _switchMode(
        defaultMode == EditorMode.cde ? EditorMode.agc : EditorMode.cde,
      );
    } else if (velocity < -threshold) {
      _switchMode(defaultMode);
    }
  }

  /// AGC 模式下的「新对话」：有记录时先确认
  Future<void> _newAgcChat() async {
    final ai = context.read<AiProvider>();
    if (ai.messages.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开启新对话'),
        content: const Text('当前对话记录将被清空，确定开始新对话吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ai.clear();
    }
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
    final terminal = context.watch<TerminalProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final showBackground =
        AppBackground.shouldShow(settings, isIdeScreen: true);

    // 首次进入时按项目类型确定默认形态：
    // 传统项目 → CDE，Loader 项目 → AGC
    final mode = _mode ??= _defaultMode(projectProvider);

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
        title: _buildTitle(projectProvider, mode, isDark),
        actions: mode == EditorMode.cde
            ? _buildCdeActions(projectProvider, terminal)
            : _buildAgcActions(),
      ),
      body: AppBackground.wrap(
        isIdeScreen: true,
        child: Stack(
          children: [
            // 主体：CDE（代码编辑）/ AGC（全屏 AI），水平滑动切换形态
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (details) =>
                  _handleModeSwipe(details.primaryVelocity ?? 0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: mode == EditorMode.cde
                    ? _buildCdeBody(
                        key: const ValueKey('cde'),
                        editorProvider: editorProvider,
                        isDark: isDark,
                        settings: settings,
                        showBackground: showBackground,
                      )
                    : const KeyedSubtree(
                        key: ValueKey('agc'),
                        child: AgcScreen(),
                      ),
              ),
            ),

            // 侧边栏打开时的遮罩（点击关闭）
            if (_showSidebar)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _showSidebar = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.28)),
                ),
              ),

            // 侧边栏：浮层滑入，不占据编辑区宽度；菜单栏随形态切换
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
                mode,
                translucent: showBackground,
              ),
            ),

            // AI 悬浮球：仅 CDE 模式显示（AGC 本身就是全屏 AI）
            if (mode == EditorMode.cde && settings.aiFloatingBallEnabled)
              AiFloatingBall(onTap: () => AiQuickChatSheet.show(context)),
          ],
        ),
        ),
      ),
    );
  }

  /// 标题：项目名 + 形态切换胶囊（点击可在 CDE / AGC 间切换）
  Widget _buildTitle(
    ProjectProvider projectProvider,
    EditorMode mode,
    bool isDark,
  ) {
    final projectName =
        projectProvider.projectPath?.split(RegExp(r'[/\\]')).last ??
            t('editor.title');
    final isAgc = mode == EditorMode.agc;
    final accent = isAgc ? const Color(0xFF7C4DFF) : const Color(0xFF007ACC);
    return Row(
      children: [
        Flexible(
          child: Text(
            projectName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () =>
              _switchMode(isAgc ? EditorMode.cde : EditorMode.agc),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.25 : 0.12),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: accent.withValues(alpha: 0.6)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isAgc ? Icons.auto_awesome : Icons.code,
                  size: 11,
                  color: isDark ? Colors.white : accent,
                ),
                const SizedBox(width: 4),
                Text(
                  isAgc ? 'AGC' : 'CDE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// CDE 模式菜单：终端 / 构建 / AI / 刷新 / 保存 / 侧边栏
  List<Widget> _buildCdeActions(
    ProjectProvider projectProvider,
    TerminalProvider terminal,
  ) {
    return [
      // 仅桌面端（本地 shell）时显示终端入口
      if (terminal.available)
        IconButton(
          icon: const Icon(Icons.terminal),
          tooltip: t('editor.terminal'),
          onPressed: () => showTerminalSheet(context),
        ),
      IconButton(
        icon: const Icon(Icons.build),
        tooltip: t('editor.build'),
        onPressed: () async {
          // GitHub / Gitee 均未登录时提醒先配置账号
          final ok = await BuildScreen.ensureSignedIn(context);
          if (!ok || !mounted) return;
          if (!context.mounted) return;
          // Loader 项目走「AI 介入 + 实际构建」两环节构建页
          final isLoader = context.read<ProjectProvider>().payload.id ==
              LoaderProjectPayload.payloadId;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => isLoader
                  ? const LoaderBuildScreen()
                  : const BuildScreen(),
            ),
          );
        },
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
    ];
  }

  /// AGC 模式菜单：新对话 / 侧边栏（对话记录 · MCP/Skills）
  List<Widget> _buildAgcActions() {
    return [
      IconButton(
        icon: const Icon(Icons.add_comment_outlined),
        tooltip: '新对话',
        onPressed: _newAgcChat,
      ),
      IconButton(
        icon: Icon(_showSidebar ? Icons.menu_open : Icons.menu),
        tooltip: t('editor.sidebar'),
        onPressed: _toggleSidebar,
      ),
    ];
  }

  /// CDE 模式主体：标签栏 + 编辑区 + 符号键盘 + 状态栏
  Widget _buildCdeBody({
    required Key key,
    required EditorProvider editorProvider,
    required bool isDark,
    required AppSettings settings,
    required bool showBackground,
  }) {
    return KeyedSubtree(
      key: key,
      child: Column(
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
    );
  }

  Widget _buildSidebar(
    ProjectProvider projectProvider,
    bool isDark,
    double width,
    EditorMode mode, {
    required bool translucent,
  }) {
    final panelColor = translucent
        ? (isDark
            ? const Color(0xF0202020)
            : const Color(0xF0FAFAFA))
        : (isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3));

    // 菜单栏随形态切换：CDE = 文件 / Agent；AGC = 对话记录 / MCP·Skills
    final isCde = mode == EditorMode.cde;

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
              tabs: isCde
                  ? [
                      Tab(text: t('editor.files')),
                      const Tab(text: 'Agent'),
                    ]
                  : const [
                      Tab(text: '对话记录'),
                      Tab(text: 'MCP/Skills'),
                    ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _sidebarTabController,
                children: isCde
                    ? [
                        _buildFilePanel(projectProvider, isDark),
                        const AiChatScreen(),
                      ]
                    : [
                        AgcHistoryPanel(
                          onClose: () =>
                              setState(() => _showSidebar = false),
                        ),
                        const AgcToolsPanel(),
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
