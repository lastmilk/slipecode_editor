import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/project.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/design_draft_service.dart';
import '../services/loader_project_service.dart';
import '../services/project_history_service.dart';
import '../services/project_trash_service.dart';
import '../services/saying_service.dart';
import '../widgets/app_background.dart';
import '../widgets/typewriter_text.dart';
import 'design_draft_editor_screen.dart';
import 'editor_screen.dart';
import 'settings_screen.dart';
import 'repo_sync_screen.dart';

/// 应用主页
///
/// 显示项目历史列表、创建/打开入口、随机语句（打字机效果）和 GitHub 登录状态栏
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
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
    _listSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
    ));
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
        .map((d) => Project(
              name: d.name,
              path: 'draft:${d.id}',
              createdAt: d.createdAt,
              lastEditedAt: d.updatedAt,
              kind: 'draft',
            ))
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设计稿不存在或已删除')),
        );
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
      final useCustom = !settings.homeSayingSourceEnabled || Random().nextBool();
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('项目目录不存在（可能来自其他设备）：\n$path')),
        );
      }
      return;
    }
    final provider = context.read<ProjectProvider>();
    await provider.openProject(path);
    if (!mounted) return;
    if (provider.projectPath != null && provider.error == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const EditorScreen()),
      );
      _loadHistory(); // 返回首页时刷新历史排序
    } else if (provider.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(provider.error!)),
      );
    }
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
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RepoSyncScreen()),
    );
    if (mounted) _loadHistory();
  }

  Future<void> _removeHistory(Project project) async {
    if (project.kind == 'draft' && project.path.startsWith('draft:')) {
      await DesignDraftService.instance
          .delete(project.path.substring('draft:'.length));
    } else {
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
                project.kind == 'draft'
                    ? '设计稿数据将被直接删除'
                    : '项目目录将移入回收站，可随时还原',
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
                      : '该操作会把项目目录从原路径移入应用回收站，'
                          '可通过「还原项目」恢复。',
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
                Text(
                  '请输入「$phrase」以确认：',
                  style: const TextStyle(fontSize: 12),
                ),
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

  /// 删除项目：设计稿直接删除；磁盘项目移入回收站
  Future<void> _deleteProject(Project project) async {
    if (!await _confirmTypedDelete(project)) return;
    if (project.kind == 'draft' && project.path.startsWith('draft:')) {
      await DesignDraftService.instance
          .delete(project.path.substring('draft:'.length));
    } else {
      final moved = await ProjectTrashService.instance.moveToTrash(project);
      if (!moved) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('项目目录不存在或删除失败')),
          );
        }
        return;
      }
      await ProjectHistoryService.instance.remove(project.path);
    }
    await _loadHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            project.kind == 'draft'
                ? '设计稿已删除'
                : '项目已移入回收站，可在「还原项目」中恢复',
          ),
        ),
      );
    }
  }

  /// 还原项目：从回收站移回原路径并重新加入列表
  Future<void> _restoreTrashed(TrashedProject entry) async {
    final path = await ProjectTrashService.instance.restore(entry);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还原失败：回收站中找不到该项目')),
        );
      }
      return;
    }
    await ProjectHistoryService.instance.touch(
      path,
      name: entry.name,
      kind: entry.kind,
    );
    await _loadHistory();
  }

  /// 打开回收站列表
  Future<void> _openTrash() async {
    final items = await ProjectTrashService.instance.list();
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
                          '回收站是空的',
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
                              '原路径：${entry.originalPath}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: TextButton(
                              onPressed: () async {
                                Navigator.of(ctx).pop();
                                await _restoreTrashed(entry);
                              },
                              child: const Text('还原'),
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
    final showBackground =
        AppBackground.shouldShow(settings, isIdeScreen: false);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      body: AppBackground.wrap(
        isIdeScreen: false,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: (isDark
                      ? [const Color(0xFF1E1E1E), const Color(0xFF121212)]
                      : [const Color(0xFFF5F7FA), const Color(0xFFE4E8EC)])
                  .map((c) =>
                      showBackground ? c.withValues(alpha: 0.75) : c)
                  .toList(),
            ),
          ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isLandscape ? 16.0 : 24.0,
            ),
            // 横屏：左侧头像 + 标题 + 文案，右侧项目列表
            child: isLandscape
                ? Row(
                    children: [
                      SizedBox(
                        width: min(320.0,
                            MediaQuery.sizeOf(context).width * 0.36),
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
                                        Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => const SettingsScreen(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Center(child: _buildHero(isDark)),
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
                : Column(
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
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      _buildHero(isDark),
                      const SizedBox(height: 12),
                      _buildSaying(isDark),
                      const SizedBox(height: 12),
                      // 项目历史列表
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
                  ),
          ),
        ),
        ),
      ),
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
              _HomeAvatar(
                avatarPath: settings.avatarPath,
                isDark: isDark,
              ),
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
              const SizedBox(height: 10),
              _buildSaying(isDark),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _openRepoImport,
              icon: const Icon(Icons.cloud_download_outlined, size: 16),
              label: const Text('导入仓库', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                        _history.isEmpty
                            ? t('home.empty')
                            : '当前筛选下没有项目',
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
      _KindFilterItem('loader', 'Loader', Icons.rocket_launch_outlined,
          Colors.blueAccent),
      _KindFilterItem('classic', '传统', Icons.folder, Colors.blue),
      _KindFilterItem(
          'draft', '设计稿', Icons.design_services_outlined, Colors.teal),
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
        border: Border.all(
          color: Colors.blueAccent.withValues(alpha: 0.25),
        ),
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
      child: const Icon(
        Icons.person,
        size: 46,
        color: Colors.white,
      ),
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
                child: Icon(
                  icon,
                  color: color,
                  size: 22,
                ),
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
