import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/legacy.dart';

import '../l10n/app_localizations.dart';
import '../models/project.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/command_registry.dart';
import '../services/design_draft_service.dart';
import '../services/desktop_platform.dart';
import '../services/desktop_prefs_service.dart';
import '../services/editor_process_service.dart';
import '../services/loader_project_service.dart';
import '../services/project_history_service.dart';
import '../services/project_trash_service.dart';
import '../services/saying_service.dart';
import '../widgets/app_background.dart';
import '../widgets/desktop/desktop_dialogs.dart';
import '../widgets/global_ai_workspace.dart';
import '../widgets/typewriter_text.dart';
import 'design_draft_editor_screen.dart';
import 'editor_screen.dart';
import 'repo_sync_screen.dart';

/// 应用主页
///
/// 显示项目历史列表、创建/打开入口、随机语句（打字机效果）和 GitHub 登录状态栏
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  List<Project> _history = [];
  String _saying = '';
  bool _loadingHistory = true;

  /// 项目列表筛选：null 全部 / classic / loader / draft
  String? _kindFilter;

  late final AnimationController _entranceController;
  late final Animation<double> _logoFade;
  late final Animation<Offset> _listSlide;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _logoFade = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
    );
    _listSlide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
          ),
        );
    _entranceController.forward();

    // 合规说明：开屏不申请任何文件存储权限。
    // 项目默认存放在应用私有目录，外部项目通过系统文件选择器导入。
    _loadHistory();
    _loadSaying();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final items = await ProjectHistoryService.instance.list();
    // 兼容旧记录：带 .slipe.json 且 payload=loader 的目录识别为 Loader 项目
    final loaderPaths = <String>[];
    for (final item in items) {
      if (item.kind == 'classic' && Directory(item.path).existsSync()) {
        try {
          if (await LoaderProjectService.isLoaderProject(item.path)) {
            loaderPaths.add(item.path);
          }
        } catch (_) {
          // 读取失败按传统项目处理
        }
      }
    }
    if (loaderPaths.isNotEmpty) {
      for (final path in loaderPaths) {
        await ProjectHistoryService.instance.setKind(path, 'loader');
      }
    }
    final projects = loaderPaths.isEmpty
        ? items
        : await ProjectHistoryService.instance.list();

    // 设计稿也作为项目列表中的一类条目展示（点击进入图编排器）
    final drafts = await DesignDraftService.instance.list();
    final draftEntries = drafts
        .map(
          (d) => Project(
            name: d.name,
            path: 'draft:${d.id}',
            createdAt: d.createdAt,
            lastEditedAt: d.updatedAt,
            kind: 'draft',
          ),
        )
        .toList();
    final merged = [...projects, ...draftEntries]
      ..sort((a, b) => b.activityAt.compareTo(a.activityAt));
    if (!mounted) return;
    setState(() {
      _history = merged;
      _loadingHistory = false;
    });
  }

  /// 供外部（底栏新建项目后）刷新项目列表
  Future<void> reloadHistory() => _loadHistory();

  /// 打开列表条目：设计稿 → 图编排器；其余 → 磁盘项目
  Future<void> _openEntry(Project project) async {
    if (project.kind == 'draft') {
      final id = project.path.substring('draft:'.length);
      final draft = await DesignDraftService.instance.byId(id);
      if (!mounted) return;
      if (draft == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设计稿不存在或已删除')));
        _loadHistory();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DesignDraftEditorScreen(draft: draft),
        ),
      );
      _loadHistory();
      return;
    }
    await _openProjectPath(project.path, name: project.name);
  }

  /// 首页文案：
  /// - 未设置自定义文案 → 一言源（先缓存后拉新）
  /// - 有自定义文案且关闭一言混入 → 纯自定义随机
  /// - 有自定义文案且开启一言混入 → 各 50% 概率
  Future<void> _loadSaying() async {
    final settings = context.read<SettingsProvider>().settings;
    final custom = settings.homeCustomTexts;

    String? pickCustom() =>
        custom.isEmpty ? null : custom[Random().nextInt(custom.length)];

    if (custom.isNotEmpty) {
      final useCustom =
          !settings.homeSayingSourceEnabled || Random().nextBool();
      if (useCustom) {
        final text = pickCustom();
        if (!mounted || text == null) return;
        setState(() => _saying = text);
        return;
      }
    }

    final cached = await SayingService.instance.cached();
    if (!mounted) return;
    setState(() => _saying = cached);
    final fresh = await SayingService.instance.fetchFresh();
    if (!mounted || fresh == null || fresh == _saying) return;
    setState(() => _saying = fresh);
  }

  Future<void> _openProjectPath(String path, {String? name}) async {
    if (!Directory(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('项目目录不存在（可能来自其他设备）：\n$path')));
      }
      return;
    }
    // 桌面：Editor 是独立进程（独立地址空间 / 崩溃域）
    if (DesktopPlatform.isDesktop) {
      // 首次打开时询问一次「每次询问 / 直接关闭」
      await _resolveHubExitMode();
      if (!mounted) return;

      final step = ValueNotifier<int>(0);
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _LaunchProgressDialog(step: step, projectName: name ?? ''),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 32));
      step.value = 1;

      late EditorLaunchResult result;
      try {
        result = await EditorProcessService.instance.openProject(
          path,
          projectName: name,
          // 关闭 Hub 时用 detached 启动，Hub 退出不会影响编辑器
          detach: true,
        );
      } finally {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      }
      if (!mounted) return;
      switch (result.status) {
        case EditorLaunchStatus.launched:
          _loadHistory();
          // 窗口互斥：Hub 直接退出，返回 Hub 时由编辑器重新拉起
          await DesktopPrefsService.instance.save();
          await windowManager.destroy();
          return;
        case EditorLaunchStatus.alreadyRunning:
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('该项目已经在编辑器中打开')));
          return;
        case EditorLaunchStatus.failed:
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(result.message)));
          return;
        case EditorLaunchStatus.unsupported:
          break; // 回退到同进程编辑器
      }
    }
    final provider = context.read<ProjectProvider>();
    await provider.openProject(path);
    if (!mounted) return;
    if (provider.projectPath != null && provider.error == null) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const EditorScreen()));
      _loadHistory(); // 返回首页时刷新历史排序
    } else if (provider.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(provider.error!)));
    }
  }

  /// 确定 Hub 打开项目后的处理方式
  ///
  /// 现在只有两种：直接关闭 Hub（推荐），或每次打开前询问。
  /// 「隐藏 Hub」已移除：部分 Wayland 合成器上隐藏窗口仍参与输入分发，
  /// 会让编辑器窗口点不动。
  Future<String> _resolveHubExitMode() async {
    final prefs = DesktopPrefsService.instance;
    final stored = normalizeHubExitMode(prefs.hubExitMode);
    if (stored != 'ask') return stored;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('打开项目后，Hub 如何处理？'),
        content: const Text(
          '项目会在独立的编辑器窗口中打开，Hub 将退出。\n'
          '返回 Hub 时会自动重新拉起。\n'
          '该选项之后可在「偏好设置」中修改。',
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('close'),
            child: const Text('关闭 Hub'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('ask'),
            child: const Text('每次询问我'),
          ),
        ],
      ),
    );
    if (choice == 'ask') return 'ask';
    prefs.update(() => prefs.hubExitMode = 'close');
    return 'close';
  }

  /// 用系统文件选择器选择项目目录
  Future<void> _openExistingProject() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: t('home.openProject'),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${t('home.filePickerUnavailable')}: $e')),
        );
      }
      return;
    }
    if (path == null || path.isEmpty) return; // 用户取消
    await _openProjectPath(path);
  }

  /// 导入仓库（原项目同步里的入口，现与「打开项目」并排）
  Future<void> _openRepoImport() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const RepoSyncScreen()));
    if (mounted) _loadHistory();
  }

  Future<void> _removeHistory(Project project) async {
    if (project.kind == 'draft' && project.path.startsWith('draft:')) {
      await DesignDraftService.instance.delete(
        project.path.substring('draft:'.length),
      );
    } else {
      // 仅从列表移除：磁盘保留，记录到回收站以便还原
      await ProjectTrashService.instance.rememberRemoved(project);
      await ProjectHistoryService.instance.remove(project.path);
    }
    await _loadHistory();
  }

  Future<void> _confirmRemove(Project project) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(project.name),
              subtitle: Text(
                project.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.playlist_remove),
              title: const Text('仅从列表移除'),
              subtitle: const Text('磁盘文件保留，可随时重新打开'),
              onTap: () => Navigator.of(ctx).pop('remove'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: Text(
                project.kind == 'draft' ? '删除设计稿' : '删除项目（从磁盘）',
                style: const TextStyle(color: Colors.red),
              ),
              subtitle: Text(
                project.kind == 'draft' ? '设计稿数据将被直接删除' : '永久删除磁盘目录（不可恢复）',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'remove') {
      await _removeHistory(project);
    } else if (action == 'delete') {
      await _deleteProject(project);
    }
  }

  /// 手动输入确认短语后才允许从磁盘删除
  Future<bool> _confirmTypedDelete(Project project) async {
    const phrase = '我知道我在干什么';
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final matched = controller.text.trim() == phrase;
          return AlertDialog(
            title: Text(
              project.kind == 'draft' ? '删除设计稿' : '删除项目',
              style: const TextStyle(color: Colors.red),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.kind == 'draft'
                      ? '该操作会直接删除设计稿数据，且无法恢复。'
                      : '该操作会永久删除磁盘上的项目目录，无法恢复。\n'
                            '如果只是想暂时隐藏，请选择「仅从列表移除」。',
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 8),
                if (project.kind != 'draft')
                  Text(
                    project.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                const SizedBox(height: 14),
                Text('请输入「$phrase」以确认：', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '我知道我在干什么',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(t('common.cancel')),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: matched
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: const Text('确认删除'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return ok == true;
  }

  /// 删除项目：设计稿直接删除；磁盘项目永久删除目录
  Future<void> _deleteProject(Project project) async {
    if (!await _confirmTypedDelete(project)) return;
    if (project.kind == 'draft' && project.path.startsWith('draft:')) {
      await DesignDraftService.instance.delete(
        project.path.substring('draft:'.length),
      );
    } else {
      final dir = Directory(project.path);
      if (!dir.existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('项目目录不存在，已仅清理列表记录')));
        }
      } else {
        try {
          await dir.delete(recursive: true);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('删除失败：$e')));
          }
          return;
        }
      }
      await ProjectHistoryService.instance.remove(project.path);
      await ProjectTrashService.instance.forgetPath(project.path);
    }
    await _loadHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(project.kind == 'draft' ? '设计稿已删除' : '项目已从磁盘永久删除'),
        ),
      );
    }
  }

  /// 还原项目：把「仅从列表移除」的项目重新加入列表（磁盘文件保留在原路径）
  Future<void> _restoreTrashed(RemovedProject entry) async {
    final ok = await ProjectTrashService.instance.restore(entry);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('还原失败：项目目录已不存在')));
      }
      return;
    }
    await ProjectHistoryService.instance.touch(
      entry.path,
      name: entry.name,
      kind: entry.kind,
    );
    await _loadHistory();
  }

  /// 从「已移除」列表永久删除磁盘目录（释放空间）
  Future<void> _deleteRemovedEntry(RemovedProject entry) async {
    final project = Project(
      name: entry.name,
      path: entry.path,
      createdAt: entry.removedAt,
      kind: entry.kind,
    );
    if (!await _confirmTypedDelete(project)) return;
    final dir = Directory(entry.path);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
        return;
      }
    }
    await ProjectTrashService.instance.forget(entry.id);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('项目已从磁盘永久删除')));
    }
  }

  /// 打开回收站列表
  Future<void> _openTrash() async {
    final items = await ProjectTrashService.instance.listRestorable();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.restore, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      '还原项目',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${items.length} 个',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          '暂无可还原的项目（仅从列表移除的项目会出现在这里）',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final entry = items[index];
                          return ListTile(
                            leading: const Icon(Icons.folder_delete_outlined),
                            title: Text(entry.name),
                            subtitle: Text(
                              '项目路径：${entry.path}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '永久删除（释放磁盘空间）',
                                  icon: const Icon(
                                    Icons.delete_forever,
                                    size: 20,
                                    color: Colors.red,
                                  ),
                                  onPressed: () async {
                                    Navigator.of(ctx).pop();
                                    await _deleteRemovedEntry(entry);
                                  },
                                ),
                                TextButton(
                                  onPressed: () async {
                                    Navigator.of(ctx).pop();
                                    await _restoreTrashed(entry);
                                  },
                                  child: const Text('还原'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 首页按显示范围决定是否叠加背景图；显示时降低渐变不透明度让背景可见
    final settings = context.watch<SettingsProvider>().settings;
    final showBackground = AppBackground.shouldShow(
      settings,
      isIdeScreen: false,
    );
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return CallbackShortcuts(
      // 桌面：Ctrl/Cmd+O 直接选择本地项目目录
      bindings: DesktopPlatform.isDesktop
          ? {desktopActivator(LogicalKeyboardKey.keyO): _openExistingProject}
          : const <ShortcutActivator, VoidCallback>{},
      child: Focus(
        autofocus: DesktopPlatform.isDesktop,
        child: Scaffold(
          body: AppBackground.wrap(
            isIdeScreen: false,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors:
                      (isDark
                              ? [
                                  const Color(0xFF1E1E1E),
                                  const Color(0xFF121212),
                                ]
                              : [
                                  const Color(0xFFF5F7FA),
                                  const Color(0xFFE4E8EC),
                                ])
                          .map(
                            (c) =>
                                showBackground ? c.withValues(alpha: 0.75) : c,
                          )
                          .toList(),
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isLandscape ? 16.0 : 24.0,
                  ),
                  // 桌面：项目列 + 全局 AI；手机横屏：头像文案 + 项目列表
                  child: DesktopPlatform.isDesktop
                      ? _buildDesktopLayout(isDark)
                      : isLandscape
                      ? Row(
                          children: [
                            SizedBox(
                              width: min(
                                320.0,
                                MediaQuery.sizeOf(context).width * 0.36,
                              ),
                              child: Column(
                                children: [
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '还原项目',
                                          icon: const Icon(Icons.restore),
                                          onPressed: _openTrash,
                                        ),
                                        IconButton(
                                          tooltip: t('home.preferences'),
                                          icon: const Icon(Icons.tune),
                                          onPressed: () =>
                                              showSettingsDialog(context),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildHero(isDark),
                                          const SizedBox(height: 16),
                                          _buildSaying(isDark),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            VerticalDivider(
                              width: 17,
                              thickness: 1,
                              color: isDark ? Colors.white10 : Colors.black12,
                            ),
                            Expanded(child: _buildHistoryList(isDark)),
                          ],
                        )
                      : _buildProfileProjectColumn(isDark),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(bool isDark) {
    return Row(
      children: [
        SizedBox(width: 340, child: _buildProfileProjectColumn(isDark)),
        VerticalDivider(
          width: 17,
          thickness: 1,
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        Expanded(
          child: GlobalAiWorkspace(
            projects: _history
                .where((project) => project.kind != 'draft')
                .toList(growable: false),
          ),
        ),
      ],
    );
  }

  /// 手机竖屏与桌面左栏共用：设置入口、头像、文案和项目历史列表。
  Widget _buildProfileProjectColumn(bool isDark) {
    return Column(
      children: [
        // 右上角只保留偏好设置入口，其余功能已移到底栏 / 我的
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: '还原项目',
              icon: const Icon(Icons.restore),
              onPressed: _openTrash,
            ),
            IconButton(
              tooltip: t('home.preferences'),
              icon: const Icon(Icons.tune),
              onPressed: () => showSettingsDialog(context),
            ),
          ],
        ),
        _buildHero(isDark),
        const SizedBox(height: 12),
        _buildSaying(isDark),
        const SizedBox(height: 12),
        Expanded(
          child: SlideTransition(
            position: _listSlide,
            child: FadeTransition(
              opacity: _entranceController,
              child: _buildHistoryList(isDark),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 头像 + 自定义标题（账号信息统一在「我的」中查看）
  Widget _buildHero(bool isDark) {
    return FadeTransition(
      opacity: _logoFade,
      child: Consumer<SettingsProvider>(
        builder: (context, settingsProvider, _) {
          final settings = settingsProvider.settings;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (DesktopPlatform.isDesktop) ...[
                Text(
                  'SLIPE HUB · 项目中心',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _HomeAvatar(avatarPath: settings.avatarPath, isDark: isDark),
              const SizedBox(height: 8),
              Text(
                settings.homeTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 随机语句（打字机效果，可在偏好设置中关闭）
  Widget _buildSaying(bool isDark) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        if (!settings.settings.showSaying) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: 48,
          child: _saying.isEmpty
              ? const SizedBox.shrink()
              : TypewriterText(
                  text: _saying,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
        );
      },
    );
  }

  Widget _buildHistoryList(bool isDark) {
    if (_loadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = _kindFilter == null
        ? _history
        : _history.where((p) => p.kind == _kindFilter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 打开项目 / 导入仓库（位于一言文案与筛选条之间）
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _openExistingProject,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(
                t('home.openProject'),
                style: const TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _openRepoImport,
              icon: const Icon(Icons.cloud_download_outlined, size: 16),
              label: const Text('导入仓库', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _buildKindFilter(),
        const SizedBox(height: 8),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 品牌 logo（空列表时展示）
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Image.asset(
                          'assets/logo/slipe_logo.jpg',
                          width: 76,
                          height: 76,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _history.isEmpty ? t('home.empty') : '当前筛选下没有项目',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _LastEditedCard(
                          project: filtered.first,
                          isDark: isDark,
                          onTap: () => _openEntry(filtered.first),
                        ),
                      );
                    }
                    final project = filtered[index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ProjectCard(
                        project: project,
                        isDark: isDark,
                        onTap: () => _openEntry(project),
                        onLongPress: () => _confirmRemove(project),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 项目类型筛选（设计稿 / 传统项目 / Loader 项目用不同图标）
  Widget _buildKindFilter() {
    const items = <_KindFilterItem>[
      _KindFilterItem(null, '全部', Icons.apps, Colors.blueGrey),
      _KindFilterItem(
        'loader',
        'Loader',
        Icons.rocket_launch_outlined,
        Colors.blueAccent,
      ),
      _KindFilterItem('classic', '传统', Icons.folder, Colors.blue),
      _KindFilterItem(
        'draft',
        '设计稿',
        Icons.design_services_outlined,
        Colors.teal,
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: Icon(
                  item.icon,
                  size: 14,
                  color: _kindFilter == item.value ? item.color : null,
                ),
                label: Text(item.label, style: const TextStyle(fontSize: 11)),
                selected: _kindFilter == item.value,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _kindFilter = item.value),
              ),
            ),
        ],
      ),
    );
  }
}

/// 项目列表类型筛选项
class _KindFilterItem {
  final String? value;
  final String label;
  final IconData icon;
  final Color color;

  const _KindFilterItem(this.value, this.label, this.icon, this.color);
}

/// 「上次编辑」卡片：展示最近编辑的项目与相对时间
class _LastEditedCard extends StatelessWidget {
  const _LastEditedCard({
    required this.project,
    required this.isDark,
    required this.onTap,
  });

  final Project project;
  final bool isDark;
  final VoidCallback onTap;

  /// 相对时间：刚刚 / x 分钟前 / 昨天 HH:mm / MM-dd
  static String relativeTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    if (day == today) return '今天 $hhmm';
    if (today.difference(day).inDays == 1) return '昨天 $hhmm';
    return '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1F3A5F), const Color(0xFF2D2D30)]
              : [const Color(0xFFE3F2FD), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.25)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.history, color: Colors.blueAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('home.lastEdited'),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      relativeTime(project.activityAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                t('home.continue'),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页头像
///
/// 用户设置过头像时显示自定义图片；否则使用默认头像
/// （渐变圆 + 人像图标，新注册用户即为此样式）。
class _HomeAvatar extends StatelessWidget {
  const _HomeAvatar({required this.avatarPath, required this.isDark});

  final String avatarPath;
  final bool isDark;

  static const double _size = 84;

  @override
  Widget build(BuildContext context) {
    final file = avatarPath.isEmpty ? null : File(avatarPath);
    final hasImage = file != null && file.existsSync();

    return Tooltip(
      message: t('home.account'),
      child: Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.blueAccent.withValues(alpha: 0.45),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipOval(
          child: hasImage
              ? Image.file(
                  file,
                  fit: BoxFit.cover,
                  width: _size,
                  height: _size,
                  errorBuilder: (_, _, _) => _buildDefault(),
                )
              : _buildDefault(),
        ),
      ),
    );
  }

  /// 默认头像（新用户）
  Widget _buildDefault() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0175C2), Color(0xFF13B9FD)],
        ),
      ),
      child: const Icon(Icons.person, size: 46, color: Colors.white),
    );
  }
}

/// 项目历史卡片
class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.isDark,
    required this.onTap,
    required this.onLongPress,
  });

  final Project project;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final isLoader = project.kind == 'loader';
    final isDraft = project.kind == 'draft';
    final icon = isLoader
        ? Icons.rocket_launch_outlined
        : (isDraft ? Icons.design_services_outlined : Icons.folder);
    final color = isDraft ? Colors.teal : Colors.blueAccent;
    final kindLabel = isLoader
        ? 'Loader 项目'
        : (isDraft ? '设计稿 · 点击继续编排' : '传统项目');
    return Material(
      color: isDark ? const Color(0xFF2D2D30) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      kindLabel,
                      style: TextStyle(
                        fontSize: 10,
                        color: color.withValues(alpha: 0.9),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      project.path.startsWith('draft:')
                          ? '可视化有向图编排'
                          : project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: isDark ? Colors.white38 : Colors.black26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 打开项目时的两阶段启动进度（Hub 侧）
///
/// 用确定进度条代替无限转圈，避免启动期间动画卡顿的观感。
class _LaunchProgressDialog extends StatelessWidget {
  const _LaunchProgressDialog({required this.step, required this.projectName});

  /// 0：正在打开项目；1：正在拉起编辑器窗口
  final ValueNotifier<int> step;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在启动编辑器'),
      content: SizedBox(
        width: 360,
        child: ValueListenableBuilder<int>(
          valueListenable: step,
          builder: (context, value, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(
                  context,
                  '打开项目${projectName.isEmpty ? '' : '「$projectName」'}',
                  done: value > 0,
                ),
                const SizedBox(height: 10),
                _row(context, '关闭 Hub 并拉起项目', done: value > 1, active: value == 1),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: value == 0 ? 0.35 : 0.75,
                    minHeight: 3,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label, {
    required bool done,
    bool active = false,
  }) {
    final color = done || active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).disabledColor;
    return Row(
      children: [
        Icon(
          done
              ? Icons.check_circle
              : (active ? Icons.radio_button_checked : Icons.radio_button_unchecked),
          size: 16,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
