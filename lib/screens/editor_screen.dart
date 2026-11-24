import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/editor_diagnostic.dart';
import '../models/file_node.dart';
import '../models/open_file.dart';
import '../payloads/loader/loader_project_payload.dart';
import '../providers/ai_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/github_provider.dart';
import '../providers/local_build_provider.dart';
import '../providers/lsp_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../providers/toolchain_provider.dart';
import '../services/ai_change_journal.dart';
import '../services/command_registry.dart';
import '../services/dart_class_template.dart';
import '../services/desktop_platform.dart';
import '../services/desktop_prefs_service.dart';
import '../services/editor_process_service.dart';
import '../services/file_service.dart';
import '../services/lsp/lsp_manager.dart';
import '../services/lsp/lsp_types.dart';
import '../services/lua/lua_keyboard_interceptor.dart';
import '../services/lua/lua_runtime_service.dart';
import '../services/project_history_service.dart';
import '../services/project_search_service.dart';
import '../services/security_service.dart';
import '../services/toolchain/toolchain_models.dart';
import '../services/volume_key_service.dart';
import '../widgets/ai_floating_ball.dart';
import '../widgets/ai_quick_chat.dart';
import '../widgets/app_background.dart';
import '../widgets/desktop/desktop_dialogs.dart';
import '../widgets/code_editor.dart';
import '../widgets/desktop/activity_bar.dart';
import '../widgets/desktop/bottom_panel.dart';
import '../widgets/desktop/command_palette.dart';
import '../widgets/desktop/desktop_shell.dart';
import '../widgets/desktop/desktop_status_bar.dart';
import '../widgets/desktop/desktop_window_host.dart';
import '../widgets/desktop/embedded_terminal.dart';
import '../widgets/desktop/global_search_panel.dart';
import '../widgets/desktop/lsp_hover_card.dart';
import '../widgets/desktop/menu_bar.dart';
import '../widgets/desktop/quick_open.dart';
import '../widgets/editor_tabs.dart';
import '../widgets/file_tree.dart';
import '../widgets/symbol_keypad.dart';
import 'agc_screen.dart';
import 'ai_chat_screen.dart';
import 'terminal_screen.dart';

/// 编辑器形态
///
/// - [cde]：传统 IDE 形态（代码编辑为主），菜单栏为「文件 / Agent」
/// - [agc]：AI 对话形态（AI 生成为主），菜单栏为「对话记录 / MCP·Skills」
enum EditorMode { cde, agc }

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

  /// 当前编辑器形态（首次 build 时按项目载荷确定默认值）
  EditorMode? _mode;

  /// 侧边栏标签控制器（0=文件，1=Agent）
  late final TabController _sidebarTabController;

  /// 当前编辑器状态，用于音量键驱动补全
  final GlobalKey<CodeEditorState> _codeEditorKey =
      GlobalKey<CodeEditorState>();

  final FileService _fileService = FileService();

  /// 桌面：项目内文件检索（快速打开 / 全局搜索）
  final ProjectSearchService _searchService = ProjectSearchService();

  /// 桌面侧边栏当前分区：0=资源管理器，1=全局搜索，2=AI 助手
  int _desktopSection = 0;

  /// 桌面底部面板当前页：0=问题，1=输出，2=终端，3=构建
  int _desktopPanelTab = 0;

  /// 当前光标位置（1 基，状态栏展示）
  /// 用 ValueNotifier 只刷新状态栏，避免光标移动导致整屏重建
  final ValueNotifier<(int, int)> _cursorPos = ValueNotifier((1, 1));

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
    LuaRuntimeService.instance.addListener(_onLuaRuntimeChanged);
  }

  void _onLuaRuntimeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // 不再自动保存：仅关闭标签 / 主动保存 / 退出确认时落盘
    _sidebarTabController.dispose();
    _cursorPos.dispose();
    _settingsProvider?.removeListener(_syncVolumeKeyListener);
    LuaRuntimeService.instance.removeListener(_onLuaRuntimeChanged);
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
    if (editorProvider.hasUnsavedChanges) {
      final count = editorProvider.openFiles
          .where((file) => file.isModified)
          .length;
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

  /// 返回 Hub：确认未保存改动后关闭编辑器窗口，并恢复/拉起 Hub
  Future<void> _returnToHub() async {
    final ok = await _confirmExit();
    if (!ok || !mounted) return;
    await DesktopWindowHost.instance.requestClose();
  }

  /// 标题栏项目名：多项目管理菜单（打开文件夹 / 最近项目）
  Future<void> _showProjectSwitcher(BuildContext anchorContext) async {
    final box = anchorContext.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final RelativeRect position;
    if (box != null && overlayBox != null && box.hasSize) {
      final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
      position = RelativeRect.fromRect(
        Rect.fromLTWH(
          offset.dx,
          offset.dy + box.size.height + 4,
          box.size.width,
          0,
        ),
        Offset.zero & overlayBox.size,
      );
    } else {
      position = const RelativeRect.fromLTRB(240, 44, 0, 0);
    }

    final currentPath = context.read<ProjectProvider>().projectPath ?? '';
    final recent = await ProjectHistoryService.instance.list();
    if (!mounted) return;

    const openFolder = '__open_folder__';
    final action = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
      items: [
        const PopupMenuItem<String>(
          value: openFolder,
          height: 42,
          child: Row(
            children: [
              Icon(Icons.folder_open_outlined, size: 16),
              SizedBox(width: 10),
              Text('打开文件夹…', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text('最近', style: TextStyle(fontSize: 11)),
        ),
        for (final project in recent.take(12))
          PopupMenuItem<String>(
            value: project.path,
            height: 46,
            child: _RecentProjectTile(
              name: project.name,
              path: project.path,
              current: project.path == currentPath,
            ),
          ),
      ],
    );

    if (!mounted || action == null) return;
    if (action == openFolder) {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '打开项目文件夹',
      );
      if (picked == null || !mounted) return;
      await _switchToProject(picked);
      return;
    }
    if (action == currentPath) return;
    await _switchToProject(action);
  }

  /// 切换到另一个项目：拉起新编辑器窗口后关闭当前窗口（不弹 Hub）
  Future<void> _switchToProject(String path) async {
    if (!DesktopPlatform.isDesktop) return;
    final ok = await DesktopWindowHost.instance.confirmUnsavedChanges();
    if (!ok || !mounted) return;
    final name = p.basename(path);
    final result = await EditorProcessService.instance.openProject(
      path,
      projectName: name,
      detach: true,
    );
    if (!mounted) return;
    if (result.ok) {
      await ProjectHistoryService.instance.touch(path, name: name);
      await DesktopWindowHost.instance.destroyWithoutHub();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message.isEmpty ? '无法打开项目：$path' : result.message),
      ),
    );
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
                        .map(
                          (entry) =>
                              '${entry.action}  ${entry.path.split(RegExp(r'[/\\\\]')).last}',
                        )
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
    final lsp = context.read<LspProvider>();
    if (!file.isModified) {
      lsp.closeDocument(file.path);
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
    lsp.closeDocument(file.path);
    editorProvider.closeFile(file.path);
  }

  Future<void> _handleFileTap(String path) async {
    final editorProvider = context.read<EditorProvider>();
    final opened = await editorProvider.openFile(path);
    if (opened == null || !mounted) return;
    // 打开成功后自动收起侧边栏（小屏手机可立刻看到代码）；
    // 横屏下侧边栏常驻，不收起（与编辑器并排操作）
    if (MediaQuery.orientationOf(context) != Orientation.landscape) {
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

  /// AGC 模式下的「新对话」：创建新会话（当前会话保留在对话记录中）
  Future<void> _newAgcChat() async {
    final ai = context.read<AiProvider>();
    if (ai.messages.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开启新对话'),
        content: const Text('当前对话会保存在「对话记录」中，确定开始新对话吗？'),
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
      ai.startNewSession();
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
      final active = editorProvider.activeFile;
      if (active != null) {
        context.read<LspProvider>().didSave(active.path, active.content);
      }
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
    final name = await _promptName(title: t('editor.newFolder'), hint: 'lib');
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
    await _handleNodeAction(node, action);
  }

  // ---------------------------------------------------------------------------
  // 桌面：打开文件夹 / 快速打开 / 命令与快捷键
  // ---------------------------------------------------------------------------

  /// 选择本地文件夹作为当前项目
  Future<void> _openFolderDesktop() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: t('desktop.openFolder'),
      );
    } catch (e) {
      _snack('${t('desktop.openFolder')}: $e', error: true);
      return;
    }
    if (path == null || path.isEmpty || !mounted) return;
    await _openFolderPath(path);
  }

  Future<void> _openFolderPath(String path) async {
    if (!Directory(path).existsSync()) {
      _snack('${t('desktop.openFolder')}: $path', error: true);
      return;
    }
    final projectProvider = context.read<ProjectProvider>();
    await projectProvider.openProject(path);
    if (!mounted) return;
    if (projectProvider.error != null) {
      _snack(projectProvider.error!, error: true);
    }
  }

  /// 快速打开：项目内文件模糊匹配（`:行号` 由 P2 的光标定位接管）
  Future<void> _quickOpenDesktop() async {
    final rootPath = context.read<ProjectProvider>().projectPath;
    if (rootPath == null) {
      _snack(t('desktop.noProject'));
      return;
    }
    final files = await _searchService.listFiles(rootPath);
    if (!mounted) return;
    if (files.isEmpty) {
      _snack(t('desktop.search.noResults'));
      return;
    }
    final result = await showQuickOpen(
      context: context,
      rootPath: rootPath,
      files: files,
    );
    if (result == null || !mounted) return;
    await _openFileAt(
      result.path,
      line: result.line ?? 1,
      column: result.column ?? 1,
    );
  }

  /// 打开文件并定位到指定行列（1 基，快速打开 / 全局搜索 / 问题面板）
  Future<void> _openFileAt(String path, {int line = 1, int column = 1}) async {
    await _handleFileTap(path);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _codeEditorKey.currentState?.revealLine(line, column: column);
    });
  }

  Future<void> _openSettings() async {
    await showSettingsDialog(context);
  }

  Future<void> _openBuildPage() async {
    // 构建依赖 GitHub Actions / Gitee Go，未登录任何平台时先提示配置账号
    // 桌面端提供本地构建，无需登录
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    if (!DesktopPlatform.isDesktop && !github.isSignedIn && !gitee.isSignedIn) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要配置 Git 账号'),
          content: const Text(
            '云端构建需要先在首页登录 GitHub 或 Gitee 账号，'
            '登录后即可使用构建功能。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    // Loader 项目走「AI 介入 + 实际构建」两环节构建页
    final isLoader =
        context.read<ProjectProvider>().payload.id ==
        LoaderProjectPayload.payloadId;
    await showBuildDialog(context, loader: isLoader);
  }

  Future<void> _toggleTheme() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await context.read<SettingsProvider>().setThemeMode(
      isDark ? ThemeMode.light : ThemeMode.dark,
    );
  }

  /// 自绘标题栏最左侧的形态切换按钮（IDE ⇄ SOLO）
  ///
  /// 桌面端是开关式控件：滑块在 IDE / SOLO 之间平移，
  /// 同时布局中的 AI 面板与活动栏做对应的位移动画。
  Widget _buildModeSwitchButton(bool isDark) {
    // 桌面端：在 IDE 与 SOLO 之间切换布局（SOLO 把 AI 面板常驻到左侧，
    // 代码区仍然保留），而不是切到手机端的纯 AI 模式。
    if (DesktopPlatform.isDesktop) {
      final solo = DesktopPrefsService.instance.soloLayout;
      return _LayoutSwitch(
        solo: solo,
        isDark: isDark,
        onChanged: (value) {
          final prefs = DesktopPrefsService.instance;
          setState(() {
            prefs.update(() => prefs.soloLayout = value);
          });
        },
      );
    }
    final isAgc = _mode == EditorMode.agc;
    final accent = isAgc ? const Color(0xFF7C4DFF) : const Color(0xFF007ACC);
    return Tooltip(
      message: isAgc ? '切换到 CDE（代码模式）' : '切换到 SOLO（AI 模式）',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _switchMode(isAgc ? EditorMode.cde : EditorMode.agc),
        child: Container(
          width: 36,
          height: 28,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.26 : 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isAgc ? Icons.auto_awesome : Icons.code,
                size: 13,
                color: isDark ? Colors.white : accent,
              ),
              const SizedBox(height: 1),
              Text(
                isAgc ? 'SOLO' : 'CDE',
                style: TextStyle(
                  fontSize: 8,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white70 : accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openToolchainScreen() async {
    await showToolchainDialog(context);
  }

  /// 打开插件中心（已安装 / 插件市场）
  Future<void> _openPluginsScreen() async {
    await showPluginsDialog(context);
  }

  /// 打开构建页（桌面活动栏入口，本地/云端在页内切换）
  Future<void> _openBuildScreen() async {
    final isLoader =
        context.read<ProjectProvider>().payload.id ==
        LoaderProjectPayload.payloadId;
    await showBuildDialog(context, loader: isLoader);
  }

  /// 侧边栏分区：重复点击同一分区时收起/展开
  void _selectDesktopSection(int section) {
    final prefs = DesktopPrefsService.instance;
    setState(() {
      if (_desktopSection == section) {
        prefs.update(() => prefs.sidebarVisible = !prefs.sidebarVisible);
      } else {
        _desktopSection = section;
        prefs.update(() => prefs.sidebarVisible = true);
      }
    });
  }

  void _toggleDesktopSidebar() {
    final prefs = DesktopPrefsService.instance;
    setState(
      () => prefs.update(() => prefs.sidebarVisible = !prefs.sidebarVisible),
    );
  }

  void _toggleDesktopPanel() {
    final prefs = DesktopPrefsService.instance;
    setState(
      () => prefs.update(() => prefs.panelVisible = !prefs.panelVisible),
    );
  }

  /// 展开底部面板并切到指定页（0=问题 1=输出 2=终端 3=构建）
  void _showDesktopPanelTab(int index) {
    final prefs = DesktopPrefsService.instance;
    setState(() {
      _desktopPanelTab = index;
      prefs.update(() => prefs.panelVisible = true);
    });
  }

  void _resizeDesktopSidebar(double delta) {
    final prefs = DesktopPrefsService.instance;
    setState(() {
      prefs.update(() {
        prefs.sidebarWidth = (prefs.sidebarWidth + delta).clamp(180.0, 480.0);
      });
    });
  }

  void _resetDesktopSidebar() {
    final prefs = DesktopPrefsService.instance;
    setState(() => prefs.update(() => prefs.sidebarWidth = 260));
  }

  void _resizeAiPanel(double delta) {
    final prefs = DesktopPrefsService.instance;
    setState(() {
      prefs.update(() {
        prefs.aiPanelWidth = (prefs.aiPanelWidth - delta).clamp(280.0, 720.0);
      });
    });
  }

  void _resetAiPanel() {
    final prefs = DesktopPrefsService.instance;
    setState(() => prefs.update(() => prefs.aiPanelWidth = 360));
  }

  void _resizeDesktopPanel(double delta) {
    final prefs = DesktopPrefsService.instance;
    setState(() {
      prefs.update(() {
        prefs.panelHeight = (prefs.panelHeight - delta).clamp(120.0, 720.0);
      });
    });
  }

  void _resetDesktopPanel() {
    final prefs = DesktopPrefsService.instance;
    setState(() => prefs.update(() => prefs.panelHeight = 220));
  }

  /// 拖放：目录直接打开为项目，文件在需要时以所在目录建项目后打开
  Future<void> _handleDesktopDrop(List<DropItem> items) async {
    if (items.isEmpty) return;
    final path = items.first.path;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await _openFolderPath(path);
      return;
    }
    if (type != FileSystemEntityType.file) return;
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null) {
      await _openFolderPath(p.dirname(path));
      if (!mounted) return;
    }
    await _handleFileTap(path);
  }

  /// 文件树右键菜单（桌面）：在鼠标位置弹出
  Future<void> _showNodeMenuAt(FileNode node, Offset position) async {
    final payload = context.read<ProjectProvider>().payload;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (node.isDirectory) ...[
          PopupMenuItem(value: 'newFile', child: Text(t('editor.newFile'))),
          PopupMenuItem(value: 'newFolder', child: Text(t('editor.newFolder'))),
          if (payload.isFlutter)
            PopupMenuItem(
              value: 'newDartClass',
              child: Text(t('editor.newDartClass')),
            ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(value: 'rename', child: Text(t('editor.rename'))),
        PopupMenuItem(value: 'delete', child: Text(t('editor.delete'))),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copyPath',
          child: Text(t('desktop.action.copyPath')),
        ),
        PopupMenuItem(value: 'reveal', child: Text(t('desktop.action.reveal'))),
      ],
    );
    if (!mounted || action == null) return;
    await _handleNodeAction(node, action);
  }

  Future<void> _handleNodeAction(FileNode node, String action) async {
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
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: node.path));
        _snack(t('desktop.action.copyPath'));
      case 'reveal':
        await DesktopPlatform.revealInFileManager(node.path);
    }
  }

  /// 标签页右键菜单（桌面）
  Future<void> _showTabMenu(OpenFile file, Offset position) async {
    final editor = context.read<EditorProvider>();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'close',
          child: Text(t('desktop.action.closeTab')),
        ),
        PopupMenuItem(
          value: 'closeOthers',
          child: Text(t('desktop.action.closeOthers')),
        ),
        PopupMenuItem(
          value: 'closeAll',
          child: Text(t('desktop.action.closeAll')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copyPath',
          child: Text(t('desktop.action.copyPath')),
        ),
        PopupMenuItem(value: 'reveal', child: Text(t('desktop.action.reveal'))),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'close':
        await _handleCloseTab(file);
      case 'closeOthers':
        final others = editor.openFiles
            .where((f) => f.path != file.path)
            .toList();
        for (final other in others) {
          if (!mounted) return;
          await _handleCloseTab(other);
        }
      case 'closeAll':
        final all = List<OpenFile>.from(editor.openFiles);
        for (final item in all) {
          if (!mounted) return;
          await _handleCloseTab(item);
        }
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: file.path));
        _snack(t('desktop.action.copyPath'));
      case 'reveal':
        await DesktopPlatform.revealInFileManager(file.path);
    }
  }

  /// 把文本编辑意图转发给当前聚焦的输入框（菜单「编辑」用）
  void _invokeTextIntent(Intent intent) {
    final target = FocusManager.instance.primaryFocus?.context ?? context;
    Actions.maybeInvoke(target, intent);
  }

  // ---------------------------------------------------------------------------
  // 桌面：命令 / 菜单 / 快捷键
  // ---------------------------------------------------------------------------

  List<DesktopCommand> _desktopCommands({
    required ProjectProvider projectProvider,
    required EditorProvider editorProvider,
    required bool terminalAvailable,
  }) {
    final hasFile = editorProvider.hasActiveFile;
    final builtins = [
      DesktopCommand(
        id: 'file.openFolder',
        label: t('desktop.openFolder'),
        activator: desktopActivator(LogicalKeyboardKey.keyO),
        run: _openFolderDesktop,
      ),
      DesktopCommand(
        id: 'file.save',
        label: t('common.save'),
        activator: desktopActivator(LogicalKeyboardKey.keyS),
        enabled: hasFile,
        run: _handleSave,
      ),
      DesktopCommand(
        id: 'file.saveAll',
        label: t('desktop.action.saveAll'),
        activator: desktopActivator(LogicalKeyboardKey.keyS, shift: true),
        enabled: editorProvider.hasUnsavedChanges,
        run: _saveAllNow,
      ),
      DesktopCommand(
        id: 'file.closeTab',
        label: t('desktop.action.closeTab'),
        activator: desktopActivator(LogicalKeyboardKey.keyW),
        enabled: hasFile,
        run: () async {
          final file = editorProvider.activeFile;
          if (file != null) await _handleCloseTab(file);
        },
      ),
      DesktopCommand(
        id: 'edit.find',
        label: t('desktop.action.find'),
        activator: desktopActivator(LogicalKeyboardKey.keyF),
        enabled: hasFile,
        run: () async => _codeEditorKey.currentState?.showFind(),
      ),
      DesktopCommand(
        id: 'edit.replace',
        label: t('desktop.action.replace'),
        activator: desktopActivator(LogicalKeyboardKey.keyH),
        enabled: hasFile,
        run: () async => _codeEditorKey.currentState?.showFind(replace: true),
      ),
      DesktopCommand(
        id: 'file.settings',
        label: t('settings.title'),
        activator: desktopActivator(LogicalKeyboardKey.comma),
        run: _openSettings,
      ),
      DesktopCommand(
        id: 'file.exit',
        label: t('desktop.action.exit'),
        run: () => DesktopWindowHost.instance.requestClose(),
      ),
      DesktopCommand(
        id: 'app.lock',
        label: t('desktop.action.lock'),
        activator: desktopActivator(LogicalKeyboardKey.keyL),
        run: () async {
          final hasPassword = await SecurityService.instance.hasPassword();
          if (!hasPassword) {
            _lspToast(t('desktop.action.lockNoPassword'));
            return;
          }
          SecurityService.requestRelock();
        },
      ),
      DesktopCommand(
        id: 'navigate.quickOpen',
        label: t('desktop.action.quickOpen'),
        activator: desktopActivator(LogicalKeyboardKey.keyP),
        enabled: projectProvider.projectPath != null,
        run: _quickOpenDesktop,
      ),
      DesktopCommand(
        id: 'view.commandPalette',
        label: t('desktop.action.commandPalette'),
        activator: desktopActivator(LogicalKeyboardKey.keyP, shift: true),
        run: _showCommandPaletteDesktop,
      ),
      DesktopCommand(
        id: 'navigate.globalSearch',
        label: t('desktop.action.globalSearch'),
        activator: desktopActivator(LogicalKeyboardKey.keyF, shift: true),
        enabled: projectProvider.projectPath != null,
        run: () async => _selectDesktopSection(1),
      ),
      DesktopCommand(
        id: 'navigate.nextTab',
        label: t('desktop.action.nextTab'),
        activator: desktopActivator(LogicalKeyboardKey.tab),
        enabled: editorProvider.openFiles.length > 1,
        run: () async => _switchDesktopTab(editorProvider),
      ),
      DesktopCommand(
        id: 'view.toggleSidebar',
        label: t('desktop.action.toggleSidebar'),
        activator: desktopActivator(LogicalKeyboardKey.keyB),
        run: () async => _toggleDesktopSidebar(),
      ),
      DesktopCommand(
        id: 'view.togglePanel',
        label: t('desktop.action.togglePanel'),
        activator: desktopActivator(LogicalKeyboardKey.keyJ),
        run: () async => _toggleDesktopPanel(),
      ),
      DesktopCommand(
        id: 'run.terminal',
        label: t('desktop.action.toggleTerminal'),
        activator: desktopActivator(LogicalKeyboardKey.backquote),
        enabled: terminalAvailable,
        run: () async => _showDesktopPanelTab(2),
      ),
      DesktopCommand(
        id: 'run.build',
        label: t('desktop.action.build'),
        activator: desktopActivator(LogicalKeyboardKey.keyB, shift: true),
        run: _openBuildScreen,
      ),
      DesktopCommand(
        id: 'run.toolchain',
        label: t('desktop.toolchain.title'),
        run: _openToolchainScreen,
      ),
      DesktopCommand(
        id: 'navigate.definition',
        label: t('desktop.lsp.definition'),
        activator: const SingleActivator(LogicalKeyboardKey.f12),
        enabled: hasFile,
        run: _lspDefinition,
      ),
      DesktopCommand(
        id: 'navigate.references',
        label: t('desktop.lsp.references'),
        activator: const SingleActivator(LogicalKeyboardKey.f12, shift: true),
        enabled: hasFile,
        run: _lspReferences,
      ),
      DesktopCommand(
        id: 'navigate.rename',
        label: t('desktop.lsp.rename'),
        activator: const SingleActivator(LogicalKeyboardKey.f2),
        enabled: hasFile,
        run: _lspRename,
      ),
      DesktopCommand(
        id: 'navigate.hover',
        label: t('desktop.lsp.hover'),
        activator: desktopActivator(LogicalKeyboardKey.keyI, shift: true),
        enabled: hasFile,
        run: _lspHover,
      ),
      DesktopCommand(
        id: 'navigate.signature',
        label: t('desktop.lsp.signature'),
        activator: desktopActivator(LogicalKeyboardKey.space, shift: true),
        enabled: hasFile,
        run: _lspSignature,
      ),
      DesktopCommand(
        id: 'edit.formatDocument',
        label: t('desktop.lsp.format'),
        activator: desktopActivator(
          LogicalKeyboardKey.keyF,
          shift: true,
          alt: true,
        ),
        enabled: hasFile,
        run: _lspFormat,
      ),
      DesktopCommand(
        id: 'edit.codeActions',
        label: t('desktop.lsp.codeActions'),
        activator: desktopActivator(LogicalKeyboardKey.period),
        enabled: hasFile,
        run: _lspCodeActions,
      ),
      DesktopCommand(
        id: 'run.lspRestart',
        label: t('desktop.lsp.restart'),
        run: () async {
          await context.read<LspProvider>().restart();
        },
      ),
    ];
    final runtime = LuaRuntimeService.instance;
    final composed = const DesktopCommandRegistry().compose(
      builtins,
      luaCommands: runtime.luaCommands,
      keymap: runtime.config.keymap,
    );
    return [
      for (final command in composed)
        command.copyWith(run: () => _executeDesktopCommand(command)),
    ];
  }

  Future<void> _executeDesktopCommand(DesktopCommand command) async {
    final runtime = LuaRuntimeService.instance;
    try {
      final will = await runtime.events.dispatch(
        'command.willExecute',
        runtime.event('command.willExecute', 'will', {'id': command.id}),
      );
      if (will.swallowed) return;
      final payload = will.event['payload'];
      if (payload is! Map || payload['id'] != command.id) {
        throw const FormatException('command.willExecute 不能修改命令 id');
      }
      await runtime.registry.invoke('command', 'execute', {'id': command.id}, (
        request,
      ) async {
        if (request['id'] != command.id) {
          throw const FormatException('command.execute 不能替换命令 id');
        }
        await command.run();
        return {'id': command.id, 'executed': true};
      });
      await runtime.events.dispatch(
        'command.didExecute',
        runtime.event('command.didExecute', 'did', {'id': command.id}),
      );
    } catch (error) {
      _lspToast('命令 ${command.id} 执行失败：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // LSP 命令
  // ---------------------------------------------------------------------------

  /// 当前编辑器上下文（活动文件 / 文本 / 光标）
  ({OpenFile file, CodeEditorState? editor, String text, int offset})?
  _lspContext() {
    final editorProvider = context.read<EditorProvider>();
    final file = editorProvider.activeFile;
    if (file == null) return null;
    final editor = _codeEditorKey.currentState;
    final text = editor?.currentText ?? file.content;
    final offset = (editor?.cursorOffset ?? 0).clamp(0, text.length);
    return (file: file, editor: editor, text: text, offset: offset);
  }

  void _lspToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _lspDefinition() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    if (!lsp.isReady) {
      _lspToast(t('desktop.lsp.notReady'));
      return;
    }
    final target = await lsp.definitionAt(ctx.file.path, ctx.text, ctx.offset);
    if (!mounted) return;
    if (target == null) {
      _lspToast(t('desktop.lsp.noDefinition'));
      return;
    }
    await _openFileAt(target.$1, line: target.$2, column: target.$3);
  }

  Future<void> _lspReferences() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    if (!lsp.isReady) {
      _lspToast(t('desktop.lsp.notReady'));
      return;
    }
    final locations = await lsp.referencesAt(
      ctx.file.path,
      ctx.text,
      ctx.offset,
    );
    if (!mounted) return;
    if (locations.isEmpty) {
      _lspToast(t('desktop.lsp.noReferences'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctxDialog) => AlertDialog(
        title: Text(t('desktop.lsp.references')),
        content: SizedBox(
          width: 560,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final location in locations)
                ListTile(
                  dense: true,
                  title: Text(
                    '${p.basename(location.$1)}:${location.$2}:${location.$3}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    location.$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                  onTap: () {
                    Navigator.of(ctxDialog).pop();
                    _openFileAt(
                      location.$1,
                      line: location.$2,
                      column: location.$3,
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctxDialog).pop(),
            child: Text(t('common.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _lspRename() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    if (!lsp.isReady) {
      _lspToast(t('desktop.lsp.notReady'));
      return;
    }
    final controller = TextEditingController(
      text: _wordAt(ctx.text, ctx.offset),
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (ctxDialog) => AlertDialog(
        title: Text(t('desktop.lsp.rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: t('desktop.lsp.newName')),
          onSubmitted: (value) => Navigator.of(ctxDialog).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctxDialog).pop(),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctxDialog).pop(controller.text),
            child: Text(t('desktop.lsp.apply')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.trim().isEmpty || !mounted) return;
    final edit = await lsp.renameAt(
      ctx.file.path,
      ctx.text,
      ctx.offset,
      newName,
    );
    if (!mounted) return;
    if (edit == null || edit.isEmpty) {
      _lspToast(t('desktop.lsp.renameFailed'));
      return;
    }
    final changed = await lsp.applyWorkspaceEdit(edit);
    if (!mounted) return;
    _lspToast(t('desktop.lsp.renamed', {'count': '${changed.length}'}));
  }

  Future<void> _lspFormat() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    if (!lsp.isReady) {
      _lspToast(t('desktop.lsp.notReady'));
      return;
    }
    final formatted = await lsp.formatDocument(ctx.file.path, ctx.text);
    if (!mounted) return;
    if (formatted == null) {
      _lspToast(t('desktop.lsp.noChanges'));
      return;
    }
    ctx.editor?.replaceAllText(formatted);
  }

  Future<void> _lspHover() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    final hover = await lsp.hoverAt(ctx.file.path, ctx.text, ctx.offset);
    if (!mounted) return;
    if (hover == null || hover.isEmpty) {
      _lspToast(t('desktop.lsp.noHover'));
      return;
    }
    await showLspHoverCard(
      context,
      title: p.basename(ctx.file.path),
      body: hover.contents,
    );
  }

  Future<void> _lspSignature() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    final help = await lsp.signatureHelpAt(ctx.file.path, ctx.text, ctx.offset);
    if (!mounted) return;
    if (help == null || help.isEmpty) {
      _lspToast(t('desktop.lsp.noSignature'));
      return;
    }
    final active = help.activeSignature.clamp(0, help.signatures.length - 1);
    final signature = help.signatures[active];
    final buffer = StringBuffer(signature.label);
    if (signature.parameters.isNotEmpty) {
      buffer.write('\n\n');
      for (var i = 0; i < signature.parameters.length; i++) {
        buffer.write(
          '${i == help.activeParameter ? '▶ ' : '  '}'
          '${signature.parameters[i].label}\n',
        );
      }
    }
    if ((signature.documentation ?? '').isNotEmpty) {
      buffer.write('\n${signature.documentation}');
    }
    await showLspHoverCard(
      context,
      title: t('desktop.lsp.signature'),
      body: buffer.toString(),
    );
  }

  Future<void> _lspCodeActions() async {
    final lsp = context.read<LspProvider>();
    final ctx = _lspContext();
    if (ctx == null) return;
    if (!lsp.isReady) {
      _lspToast(t('desktop.lsp.notReady'));
      return;
    }
    final start = math.min(
      ctx.editor?.selectionStart ?? ctx.offset,
      ctx.offset,
    );
    final end = math.max(ctx.editor?.selectionEnd ?? ctx.offset, ctx.offset);
    final actions = await lsp.codeActionsAt(
      ctx.file.path,
      ctx.text,
      start,
      end,
    );
    if (!mounted) return;
    if (actions.isEmpty) {
      _lspToast(t('desktop.lsp.noActions'));
      return;
    }
    final selected = await showDialog<LspCodeAction>(
      context: context,
      builder: (ctxDialog) => SimpleDialog(
        title: Text(t('desktop.lsp.codeActions')),
        children: [
          for (final action in actions)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctxDialog).pop(action),
              child: Row(
                children: [
                  if (action.isPreferred)
                    const Icon(Icons.star, size: 14, color: Colors.amber),
                  if (action.isPreferred) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      action.title,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    if (selected.edit != null) {
      final changed = await lsp.applyWorkspaceEdit(selected.edit!);
      if (!mounted) return;
      _lspToast(t('desktop.lsp.applied', {'count': '${changed.length}'}));
      return;
    }
    _lspToast(t('desktop.lsp.commandUnsupported'));
  }

  /// 光标处的单词（重命名默认值）
  String _wordAt(String text, int offset) {
    if (text.isEmpty || offset < 0 || offset > text.length) return '';
    var start = offset.clamp(0, text.length);
    var end = start;
    bool isWord(int code) =>
        (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        code == 95;
    while (start > 0 && isWord(text.codeUnitAt(start - 1))) {
      start--;
    }
    while (end < text.length && isWord(text.codeUnitAt(end))) {
      end++;
    }
    return text.substring(start, end);
  }

  void _showLspLogs() {
    final lsp = context.read<LspProvider>();
    showDialog<void>(
      context: context,
      builder: (ctxDialog) => AlertDialog(
        title: Text(t('desktop.lsp.logs')),
        content: SizedBox(
          width: 640,
          height: 360,
          child: lsp.logs.isEmpty
              ? Center(child: Text(t('desktop.lsp.logsEmpty')))
              : SingleChildScrollView(
                  child: SelectableText(
                    lsp.logs.join('\n'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              lsp.clearLogs();
              Navigator.of(ctxDialog).pop();
            },
            child: Text(t('common.clear')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctxDialog).pop();
              lsp.restart();
            },
            child: Text(t('desktop.lsp.restart')),
          ),
        ],
      ),
    );
  }

  void _switchDesktopTab(EditorProvider editorProvider) {
    final files = editorProvider.openFiles;
    if (files.length < 2) return;
    final activePath = editorProvider.activeFile?.path;
    final index = files.indexWhere((file) => file.path == activePath);
    final next = files[(index + 1) % files.length];
    editorProvider.setActiveFile(next.path);
  }

  Future<void> _showCommandPaletteDesktop() {
    final commands = _desktopCommands(
      projectProvider: context.read<ProjectProvider>(),
      editorProvider: context.read<EditorProvider>(),
      terminalAvailable: context.read<TerminalProvider>().available,
    );
    return showCommandPalette(context, commands);
  }

  Map<ShortcutActivator, VoidCallback> _desktopShortcutBindings(
    List<DesktopCommand> commands,
  ) {
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (final command in commands) {
      final activator = command.activator;
      if (activator == null || !command.enabled) continue;
      bindings[activator] = () => command.run();
    }
    return bindings;
  }

  List<DesktopMenuSpec> _desktopMenus({
    required ProjectProvider projectProvider,
    required EditorProvider editorProvider,
    required bool terminalAvailable,
  }) {
    final commands = _desktopCommands(
      projectProvider: projectProvider,
      editorProvider: editorProvider,
      terminalAvailable: terminalAvailable,
    );
    DesktopMenuItemSpec from(String id, {bool separatorBefore = false}) {
      final command = commands.firstWhere((item) => item.id == id);
      return DesktopMenuItemSpec(
        label: command.label,
        enabled: command.enabled,
        activator: command.activator,
        separatorBefore: separatorBefore,
        onSelected: command.enabled ? () => command.run() : null,
      );
    }

    DesktopMenuItemSpec textItem(
      String label,
      Intent intent,
      ShortcutActivator activator, {
      bool separatorBefore = false,
    }) {
      return DesktopMenuItemSpec(
        label: label,
        activator: activator,
        separatorBefore: separatorBefore,
        onSelected: () => _invokeTextIntent(intent),
      );
    }

    const cause = SelectionChangedCause.keyboard;
    return [
      DesktopMenuSpec(
        label: t('desktop.menu.file'),
        items: [
          // 桌面：编辑器独立于 Hub，提供返回项目中心的入口
          if (DesktopPlatform.isDesktop)
            DesktopMenuItemSpec(
              label: '返回项目中心（Hub）',
              onSelected: () => unawaited(_returnToHub()),
            ),
          from('file.openFolder', separatorBefore: DesktopPlatform.isDesktop),
          from('file.save', separatorBefore: true),
          from('file.saveAll'),
          from('file.closeTab', separatorBefore: true),
          from('file.settings', separatorBefore: true),
          from('file.exit'),
        ],
      ),
      DesktopMenuSpec(
        label: t('desktop.menu.edit'),
        items: [
          from('edit.find'),
          from('edit.replace'),
          textItem(
            t('desktop.action.undo'),
            const UndoTextIntent(cause),
            desktopActivator(LogicalKeyboardKey.keyZ),
            separatorBefore: true,
          ),
          textItem(
            t('desktop.action.redo'),
            const RedoTextIntent(cause),
            desktopActivator(LogicalKeyboardKey.keyY),
          ),
          textItem(
            t('desktop.action.cut'),
            const CopySelectionTextIntent.cut(cause),
            desktopActivator(LogicalKeyboardKey.keyX),
            separatorBefore: true,
          ),
          textItem(
            t('desktop.action.copy'),
            CopySelectionTextIntent.copy,
            desktopActivator(LogicalKeyboardKey.keyC),
          ),
          textItem(
            t('desktop.action.paste'),
            const PasteTextIntent(cause),
            desktopActivator(LogicalKeyboardKey.keyV),
          ),
          textItem(
            t('desktop.action.selectAll'),
            const SelectAllTextIntent(cause),
            desktopActivator(LogicalKeyboardKey.keyA),
            separatorBefore: true,
          ),
          from('edit.formatDocument', separatorBefore: true),
          from('edit.codeActions'),
        ],
      ),
      DesktopMenuSpec(
        label: t('desktop.menu.view'),
        items: [
          from('view.commandPalette'),
          from('navigate.quickOpen'),
          from('navigate.globalSearch'),
          from('navigate.definition', separatorBefore: true),
          from('navigate.references'),
          from('navigate.rename'),
          from('navigate.hover'),
          from('navigate.signature'),
          from('navigate.nextTab', separatorBefore: true),
          from('view.toggleSidebar', separatorBefore: true),
          from('view.togglePanel'),
          DesktopMenuItemSpec(
            label: DesktopPrefsService.instance.soloLayout
                ? '切换到 IDE 形态'
                : '切换到 SOLO 形态',
            separatorBefore: true,
            onSelected: () {
              final prefs = DesktopPrefsService.instance;
              setState(() {
                prefs.update(() => prefs.soloLayout = !prefs.soloLayout);
              });
            },
          ),
        ],
      ),
      DesktopMenuSpec(
        label: t('desktop.menu.run'),
        items: [
          from('run.terminal'),
          from('run.build'),
          from('run.toolchain', separatorBefore: true),
        ],
      ),
      DesktopMenuSpec(
        label: t('desktop.menu.help'),
        items: [
          DesktopMenuItemSpec(
            label: t('desktop.shortcutsTitle'),
            onSelected: _showDesktopShortcuts,
          ),
        ],
      ),
    ];
  }

  Future<void> _showDesktopShortcuts() async {
    final commands = _desktopCommands(
      projectProvider: context.read<ProjectProvider>(),
      editorProvider: context.read<EditorProvider>(),
      terminalAvailable: context.read<TerminalProvider>().available,
    ).where((command) => command.activator != null).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('desktop.shortcutsTitle')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final command in commands)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            command.label,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        Text(
                          command.shortcutLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 桌面：外壳
  // ---------------------------------------------------------------------------

  Widget _buildDesktopShell({
    required ProjectProvider projectProvider,
    required EditorProvider editorProvider,
    required bool isDark,
    required double fontSize,
    required String fontFamily,
    required bool completionEnabled,
    required bool translucent,
    required bool terminalAvailable,
  }) {
    final prefs = DesktopPrefsService.instance;
    final solo = prefs.soloLayout;
    final commands = _desktopCommands(
      projectProvider: projectProvider,
      editorProvider: editorProvider,
      terminalAvailable: terminalAvailable,
    );

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
        body: DropTarget(
          onDragDone: (details) => _handleDesktopDrop(details.files),
          child: AppBackground.wrap(
            isIdeScreen: true,
            child: CallbackShortcuts(
              bindings: _desktopShortcutBindings(commands),
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) => LuaKeyboardInterceptor.handle(
                  event,
                  events: LuaRuntimeService.instance.events,
                  bindings: _desktopShortcutBindings(commands),
                  source: 'desktop',
                ),
                child: DesktopShell(
                  menus: _desktopMenus(
                    projectProvider: projectProvider,
                    editorProvider: editorProvider,
                    terminalAvailable: terminalAvailable,
                  ),
                  titleBarLeading: _buildModeSwitchButton(isDark),
                  titleBarSettings: _openSettings,
                  titleBarActions: [
                    IconButton(
                      tooltip: '返回 Hub',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.grid_view_rounded,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                      onPressed: () => unawaited(_returnToHub()),
                    ),
                  ],
                  projectName:
                      projectProvider.projectPath
                          ?.split(RegExp(r'[/\\]'))
                          .last ??
                      '',
                  titleLeading: Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  titleBarSearch: IconButton(
                    tooltip: '快速打开（Ctrl+P）',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.search,
                      size: 16,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    onPressed: _quickOpenDesktop,
                  ),
                  onProjectMenu: _showProjectSwitcher,
                  activityBar: ActivityBar(
                    selectedIndex: _desktopSection,
                    onRight: solo,
                    items: [
                      ActivityBarItem(
                        icon: Icons.description_outlined,
                        tooltip: t('desktop.sidebar.explorer'),
                        onTap: () => _selectDesktopSection(0),
                      ),
                      ActivityBarItem(
                        icon: Icons.search,
                        tooltip: t('desktop.sidebar.search'),
                        onTap: () => _selectDesktopSection(1),
                      ),
                      ActivityBarItem(
                        icon: Icons.handyman_outlined,
                        tooltip: t('desktop.sidebar.toolchains'),
                        pushNavigation: true,
                        onTap: _openToolchainScreen,
                      ),
                      ActivityBarItem(
                        icon: Icons.extension_outlined,
                        tooltip: '插件',
                        pushNavigation: true,
                        onTap: _openPluginsScreen,
                      ),
                      ActivityBarItem(
                        icon: Icons.build_outlined,
                        tooltip: t('desktop.sidebar.build'),
                        pushNavigation: true,
                        onTap: _openBuildScreen,
                      ),
                    ],
                    onSettings: _openSettings,
                    onToggleTheme: _toggleTheme,
                  ),
                  sidebar: _buildDesktopSidebar(projectProvider, isDark),
                  sidebarVisible: prefs.sidebarVisible,
                  sidebarWidth: prefs.sidebarWidth,
                  onSidebarResize: _resizeDesktopSidebar,
                  onSidebarReset: _resetDesktopSidebar,
                  showActivityBar: true,
                  // SOLO：活动栏与文件树镜像到右侧，AI 常驻左侧
                  sidebarOnRight: solo,
                  editor: Column(
                    children: [
                      EditorTabs(
                        onRequestClose: _handleCloseTab,
                        onContextMenu: _showTabMenu,
                      ),
                      Expanded(
                        child: editorProvider.hasActiveFile
                            ? _buildEditor(
                                editorProvider,
                                isDark,
                                fontSize,
                                fontFamily,
                                completionEnabled,
                                translucent,
                              )
                            : _buildDesktopWelcome(isDark),
                      ),
                    ],
                  ),
                  bottomPanel: _buildDesktopBottomPanel(editorProvider),
                  panelVisible: solo ? false : prefs.panelVisible,
                  panelHeight: prefs.panelHeight,
                  onPanelResize: _resizeDesktopPanel,
                  onPanelReset: _resetDesktopPanel,
                  // AI 一等公民：IDE 常驻右侧，SOLO 常驻左侧（同一切换动画）
                  aiPanel: const AiChatScreen(),
                  aiPanelOnLeft: solo,
                  aiPanelWidth: prefs.aiPanelWidth,
                  onAiResize: _resizeAiPanel,
                  onAiReset: _resetAiPanel,
                  statusBar: _buildDesktopStatusBar(editorProvider),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopSidebar(ProjectProvider projectProvider, bool isDark) {
    final rootPath = projectProvider.projectPath;
    final content = switch (_desktopSection) {
      1 =>
        rootPath == null
            ? _buildDesktopPlaceholder(Icons.search, t('desktop.noProject'))
            : GlobalSearchPanel(
                rootPath: rootPath,
                onOpen: (path, line) => _openFileAt(path, line: line),
              ),
      _ => _buildFilePanel(projectProvider, isDark),
    };
    return Container(
      color: isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3),
      child: content,
    );
  }

  Widget _buildDesktopBottomPanel(EditorProvider editorProvider) {
    return BottomPanel(
      key: ValueKey('desktop-panel-$_desktopPanelTab'),
      initialIndex: _desktopPanelTab,
      onClose: _toggleDesktopPanel,
      onTabChanged: (index) {
        if (_desktopPanelTab == index) return;
        setState(() => _desktopPanelTab = index);
      },
      tabs: [
        BottomPanelTab(
          label: t('desktop.panel.problems'),
          icon: Icons.error_outline,
          badge: editorProvider.errorCount + editorProvider.warningCount == 0
              ? null
              : editorProvider.errorCount + editorProvider.warningCount,
          child: _buildDesktopProblems(editorProvider),
        ),
        BottomPanelTab(
          label: t('desktop.panel.output'),
          icon: Icons.subject,
          child: _buildDesktopOutput(),
        ),
        BottomPanelTab(
          label: t('desktop.panel.terminal'),
          icon: Icons.terminal,
          child: EmbeddedTerminal(
            key: ValueKey(
              'terminal-${context.read<ProjectProvider>().projectPath}',
            ),
            active: _desktopPanelTab == 2,
            projectPath: context.read<ProjectProvider>().projectPath,
          ),
        ),
        BottomPanelTab(
          label: t('desktop.panel.build'),
          icon: Icons.build_outlined,
          child: _buildDesktopPanelAction(
            Icons.build_outlined,
            t('desktop.build.open'),
            _openBuildPage,
          ),
        ),
      ],
    );
  }

  /// 「输出」面板：展示本地构建日志
  Widget _buildDesktopOutput() {
    final provider = context.watch<LocalBuildProvider>();
    final task = provider.current;
    if (task == null || task.logs.isEmpty) {
      return _buildDesktopPlaceholder(Icons.subject, t('desktop.output.empty'));
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: task.logs.length,
        itemBuilder: (context, index) => Text(
          task.logs[index],
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  /// 「问题」面板：汇总所有文件的诊断，点击跳转到对应位置
  Widget _buildDesktopProblems(EditorProvider editorProvider) {
    final entries = <(String, EditorDiagnostic)>[];
    editorProvider.allDiagnostics.forEach((path, diagnostics) {
      for (final diagnostic in diagnostics) {
        entries.add((path, diagnostic));
      }
    });
    if (entries.isEmpty) {
      return _buildDesktopPlaceholder(
        Icons.check_circle_outline,
        t('desktop.problems.empty'),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final (path, diagnostic) = entries[index];
        final color = diagnostic.isError
            ? const Color(0xFFE51400)
            : diagnostic.isWarning
            ? const Color(0xFFBF8803)
            : const Color(0xFF1A85FF);
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          minLeadingWidth: 16,
          leading: Icon(Icons.circle, size: 9, color: color),
          title: Text(
            diagnostic.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          subtitle: Text(
            '${p.basename(path)}:${diagnostic.start.line + 1}:'
            '${diagnostic.start.character + 1}',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          onTap: () => _openFileAt(
            path,
            line: diagnostic.start.line + 1,
            column: diagnostic.start.character + 1,
          ),
        );
      },
    );
  }

  Widget _buildDesktopPlaceholder(IconData icon, String text) {
    final theme = Theme.of(context);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopPanelAction(
    IconData icon,
    String label,
    Future<void> Function() onPressed,
  ) {
    return Center(
      child: FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildDesktopWelcome(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.code,
            size: 72,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          const SizedBox(height: 16),
          Text(
            t('desktop.welcomeOpen'),
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _openFolderDesktop,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(t('desktop.openFolder')),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopStatusBar(EditorProvider editorProvider) {
    final activeFile = editorProvider.activeFile;
    final projectPath = context.read<ProjectProvider>().projectPath;
    final projectLabel = projectPath == null
        ? t('desktop.noProject')
        : p.basename(projectPath);
    final toolchains = context.watch<ToolchainProvider>();
    final lsp = context.watch<LspProvider>();
    final lspText = lsp.isReady
        ? 'Dart ${lsp.dartVersion ?? ''}'.trim()
        : t(lsp.statusKey);
    final flutterVersion = toolchains.activeVersion(
      ToolchainKind.flutter,
      projectPath: projectPath,
    );
    final flutterResolved = toolchains.resolveExecutable(
      ToolchainKind.flutter,
      projectPath: projectPath,
    );
    return DesktopStatusBar(
      left: [
        DesktopStatusBar.item(
          projectLabel,
          icon: Icons.folder_outlined,
          tooltip: projectPath ?? '',
        ),
        if (activeFile != null)
          DesktopStatusBar.item(
            _detectLanguage(activeFile.path),
            icon: Icons.code,
          ),
        DesktopStatusBar.item(
          lspText,
          icon: lsp.state == LspManagerState.failed
              ? Icons.hub_outlined
              : Icons.hub,
          tooltip: lsp.error ?? lsp.progress ?? t('desktop.lsp.title'),
          onTap: () {
            if (lsp.isReady) {
              _showLspLogs();
            } else {
              lsp.restart();
            }
          },
        ),
        DesktopStatusBar.item(
          flutterResolved == null
              ? 'Flutter: —'
              : 'Flutter ${flutterVersion ?? 'system'}',
          icon: Icons.handyman_outlined,
          tooltip: t('desktop.toolchain.title'),
          onTap: _openToolchainScreen,
        ),
        DesktopStatusBar.item(
          '${editorProvider.errorCount} / ${editorProvider.warningCount}',
          icon: Icons.error_outline,
          tooltip: t('desktop.panel.problems'),
          onTap: () => _showDesktopPanelTab(0),
        ),
      ],
      right: [
        if (activeFile != null)
          ValueListenableBuilder<(int, int)>(
            valueListenable: _cursorPos,
            builder: (context, pos, _) => DesktopStatusBar.item(
              'Ln ${pos.$1}, Col ${pos.$2}',
              tooltip: t('editor.lines', {
                'count': '${activeFile.content.split('\n').length}',
              }),
            ),
          ),
        DesktopStatusBar.item(t('desktop.status.spaces', {'count': '2'})),
        DesktopStatusBar.item('UTF-8'),
      ],
    );
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
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    final showBackground = AppBackground.shouldShow(
      settings,
      isIdeScreen: true,
    );

    // 首次进入时按项目类型确定默认形态：
    // 传统项目 → CDE，Loader 项目 → AGC
    final mode = _mode ??= _defaultMode(projectProvider);

    // 竖屏浮层侧边栏宽度：窄屏最多占 82%，避免完全遮住代码
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth = math.min(300.0, screenWidth * 0.82);
    // 横屏常驻侧边栏宽度（与编辑器并排，挤压编辑区，VSCode 式布局）
    final dockedSidebarWidth = math.min(
      320.0,
      math.max(200.0, screenWidth * 0.3),
    );

    // 主体：CDE（代码编辑）/ AGC（全屏 AI），水平滑动切换形态
    final modeBody = GestureDetector(
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
            : const KeyedSubtree(key: ValueKey('agc'), child: AgcScreen()),
      ),
    );

    // 横屏：隐藏顶栏，功能按钮集中到右侧，左侧侧边栏（文件/Agent 或
    // 对话记录/MCP·Skills）常驻并与编辑器同时可操作
    final body = isLandscape
        ? SafeArea(
            child: Row(
              children: [
                _buildSidebar(
                  projectProvider,
                  isDark,
                  dockedSidebarWidth,
                  mode,
                  translucent: showBackground,
                  docked: true,
                ),
                Expanded(child: modeBody),
                _buildLandscapeRail(terminal, mode, isDark),
              ],
            ),
          )
        : Stack(
            children: [
              modeBody,

              // 侧边栏打开时的遮罩（点击关闭）
              if (_showSidebar)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _showSidebar = false),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.28),
                    ),
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
          );

    // 桌面宽屏：IDE / SOLO 共用同一外壳，由 soloLayout 决定 AI 侧栏位置
    if (DesktopPlatform.isDesktop && screenWidth >= 1000) {
      return _buildDesktopShell(
        projectProvider: projectProvider,
        editorProvider: editorProvider,
        isDark: isDark,
        fontSize: settings.editorFontSize,
        fontFamily: settings.fontFamily,
        completionEnabled: settings.completionEnabled,
        translucent: showBackground,
        terminalAvailable: terminal.available,
      );
    }

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
        appBar: isLandscape
            ? null
            : AppBar(
                title: _buildTitle(projectProvider, mode, isDark),
                actions: mode == EditorMode.cde
                    ? _buildCdeActions(projectProvider, terminal)
                    : _buildAgcActions(),
              ),
        body: AppBackground.wrap(isIdeScreen: true, child: body),
      ),
    );
  }

  /// 横屏右侧竖向功能栏：顶栏隐藏后所有操作按钮集中于此
  Widget _buildLandscapeRail(
    TerminalProvider terminal,
    EditorMode mode,
    bool isDark,
  ) {
    final isCde = mode == EditorMode.cde;
    final panelColor = isDark
        ? const Color(0xFF252526)
        : const Color(0xFFF3F3F3);

    return Material(
      color: panelColor,
      child: Container(
        width: 52,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: isDark ? Colors.white12 : Colors.black12),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildRailButton(
                icon: Icons.arrow_back,
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              _buildRailButton(
                icon: isCde ? Icons.auto_awesome : Icons.code,
                tooltip: isCde ? '切换到 AGC' : '切换到 CDE',
                onPressed: () =>
                    _switchMode(isCde ? EditorMode.agc : EditorMode.cde),
              ),
              Divider(
                height: 12,
                color: isDark ? Colors.white12 : Colors.black12,
              ),
              if (isCde) ...[
                // 仅桌面端（本地 shell）时显示终端入口
                if (terminal.available)
                  _buildRailButton(
                    icon: Icons.terminal,
                    tooltip: t('editor.terminal'),
                    onPressed: () => showTerminalSheet(context),
                  ),
                _buildRailButton(
                  icon: Icons.build,
                  tooltip: t('editor.build'),
                  onPressed: _openBuildScreen,
                ),
                _buildRailButton(
                  icon: Icons.auto_awesome,
                  tooltip: t('editor.ai'),
                  onPressed: _openAgentPanel,
                ),
                _buildRailButton(
                  icon: Icons.refresh,
                  tooltip: t('editor.refresh'),
                  onPressed: () =>
                      context.read<ProjectProvider>().refreshFileTree(),
                ),
                _buildRailButton(
                  icon: Icons.save,
                  tooltip: t('editor.save'),
                  onPressed: _handleSave,
                ),
              ] else ...[
                _buildRailButton(
                  icon: Icons.add_comment_outlined,
                  tooltip: '新对话',
                  onPressed: _newAgcChat,
                ),
                _buildRailButton(
                  icon: Icons.history,
                  tooltip: '对话记录',
                  onPressed: () => _sidebarTabController.animateTo(0),
                ),
                _buildRailButton(
                  icon: Icons.extension_outlined,
                  tooltip: 'MCP/Skills',
                  onPressed: () => _sidebarTabController.animateTo(1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRailButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
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
        // 桌面：编辑器是独立于 Hub 的窗口栈，提供返回项目中心入口
        if (DesktopPlatform.isDesktop) ...[
          IconButton(
            tooltip: '返回 SLIPE Hub',
            icon: const Icon(Icons.arrow_back, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 2),
        ],
        Flexible(
          child: Text(
            projectName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _switchMode(isAgc ? EditorMode.cde : EditorMode.agc),
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
                  isAgc ? 'SOLO' : 'CDE',
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
        onPressed: _openBuildScreen,
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
    bool docked = false,
  }) {
    final panelColor = translucent
        ? (isDark ? const Color(0xF0202020) : const Color(0xF0FAFAFA))
        : (isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3));

    // 菜单栏随形态切换：CDE = 文件 / Agent；AGC(SOLO) = 任务列表（常驻）
    final isCde = mode == EditorMode.cde;

    // SOLO 形态：左侧只保留任务列表，MCP / Skills 收进右上角入口
    if (!isCde) {
      return Material(
        color: panelColor,
        elevation: docked ? 0 : 12,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isDark ? Colors.white10 : Colors.black12,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.checklist_rtl,
                      size: 15,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '任务',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'MCP / Skills',
                      icon: const Icon(Icons.tune, size: 16),
                      onPressed: _showAgcTools,
                    ),
                    if (!docked)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: t('common.close'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() => _showSidebar = false),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: AgcHistoryPanel(
                  // 常驻模式下选中会话不收起侧边栏
                  onClose: docked
                      ? null
                      : () => setState(() => _showSidebar = false),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: panelColor,
      // 横屏常驻时不加浮层阴影，避免与编辑器分栏割裂
      elevation: docked ? 0 : 12,
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

  /// SOLO 形态：MCP / Skills 面板（弹窗形式，避免挤占任务列表）
  Future<void> _showAgcTools() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 760, height: 560, child: const AgcToolsPanel()),
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
                onPressed: rootPath == null
                    ? null
                    : () => _createFileDialog(rootPath),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.create_new_folder, size: 18),
                tooltip: t('editor.newFolder'),
                onPressed: rootPath == null
                    ? null
                    : () => _createDirDialog(rootPath),
              ),
              if (payload.isFlutter)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.widgets, size: 18),
                  tooltip: t('editor.newDartClass'),
                  onPressed: rootPath == null
                      ? null
                      : () => _createDartClassDialog(rootPath),
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
            onSecondaryTap: DesktopPlatform.isDesktop ? _showNodeMenuAt : null,
            openPaths: {
              for (final file in context.watch<EditorProvider>().openFiles)
                file.path,
            },
            activePath: context.watch<EditorProvider>().activeFile?.path,
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
    final lsp = context.watch<LspProvider>();
    final vibeBusy = ai.vibeBusy;

    // 保证活动文档与语言服务同步（幂等，可安全在 build 中调用）
    lsp.ensureDocument(activeFile.path, activeFile.content);

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
                  showGutter: DesktopPlatform.isDesktop,
                  diagnostics: editorProvider.diagnosticsFor(activeFile.path),
                  semanticTokens: lsp.semanticTokensFor(activeFile.path),
                  lspCompletion: lsp.isReady
                      ? (text, offset) =>
                            lsp.completionAt(activeFile.path, text, offset)
                      : null,
                  onCursorChanged: (line, column) {
                    if (!mounted) return;
                    final current = _cursorPos.value;
                    if (current.$1 == line && current.$2 == column) return;
                    _cursorPos.value = (line, column);
                  },
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
                    lsp.didChange(activeFile.path, content);
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
              t('editor.lines', {
                'count': '${activeFile.content.split('\n').length}',
              }),
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

/// 标题栏的 IDE / SOLO 开关式切换控件
///
/// 滑块做 220ms 平移，底色与文字颜色同步过渡，与布局中的 AI 面板位移呼应。
class _LayoutSwitch extends StatelessWidget {
  const _LayoutSwitch({
    required this.solo,
    required this.isDark,
    required this.onChanged,
  });

  final bool solo;
  final bool isDark;
  final ValueChanged<bool> onChanged;

  static const _duration = Duration(milliseconds: 220);
  static const _ideAccent = Color(0xFF007ACC);
  static const _soloAccent = Color(0xFF7C4DFF);

  @override
  Widget build(BuildContext context) {
    final accent = solo ? _soloAccent : _ideAccent;
    final activeColor = isDark ? Colors.white : Colors.black87;
    final inactiveColor = isDark ? Colors.white38 : Colors.black38;
    return Tooltip(
      message: solo ? '切换到 IDE 布局' : '切换到 SOLO 布局（代码 + AI 同屏）',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!solo),
        child: AnimatedContainer(
          duration: _duration,
          curve: Curves.easeOutCubic,
          width: 68,
          height: 28,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.26 : 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: _duration,
                curve: Curves.easeOutCubic,
                alignment: solo ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 30,
                  height: 22,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: _duration,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: solo ? inactiveColor : activeColor,
                        ),
                        child: const Text('IDE'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: _duration,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: solo ? activeColor : inactiveColor,
                        ),
                        child: const Text('SOLO'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 项目切换菜单中的一条最近项目（名称 + 路径 + 当前标记）
class _RecentProjectTile extends StatelessWidget {
  const _RecentProjectTile({
    required this.name,
    required this.path,
    required this.current,
  });

  final String name;
  final String path;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (current) ...[
          const SizedBox(width: 8),
          Icon(Icons.check, size: 15, color: theme.colorScheme.primary),
        ],
      ],
    );
  }
}
