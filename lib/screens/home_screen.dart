import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../providers/account_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/project_history_service.dart';
import '../services/saying_service.dart';
import '../widgets/app_background.dart';
import '../widgets/typewriter_text.dart';
import 'account_screen.dart';
import 'create_project_screen.dart';
import 'editor_screen.dart';
import 'settings_screen.dart';

/// 应用主页
///
/// 显示项目历史列表、创建/打开入口、随机语句（打字机效果）和 GitHub 登录状态栏
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  List<Project> _history = [];
  String _saying = '';
  bool _loadingHistory = true;

  late final AnimationController _entranceController;
  late final Animation<double> _logoFade;
  late final Animation<Offset> _listSlide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

    _requestPermissions();
    _loadHistory();
    _loadSaying();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entranceController.dispose();
    super.dispose();
  }

  /// 切后台时确保所有打开的改动已落盘
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused) return;
    try {
      context.read<EditorProvider>().saveAll();
    } catch (_) {
      // Provider 已销毁（例如热重启）时忽略
    }
  }

  Future<void> _requestPermissions() async {
    // 仅 Android 需要存储权限；iOS 使用文档选择器，无需申请
    if (!Platform.isAndroid) return;
    if (await Permission.storage.status != PermissionStatus.granted) {
      await Permission.storage.request();
    }
    if (await Permission.manageExternalStorage.status !=
        PermissionStatus.granted) {
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _loadHistory() async {
    final items = await ProjectHistoryService.instance.list();
    if (!mounted) return;
    setState(() {
      _history = items;
      _loadingHistory = false;
    });
  }

  /// 先显示缓存随机语句（离线可用），再尝试拉取新语句替换
  Future<void> _loadSaying() async {
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
        dialogTitle: '选择项目根目录',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件选择器不可用: $e')),
        );
      }
      return;
    }
    if (path == null || path.isEmpty) return; // 用户取消
    await _openProjectPath(path);
  }

  Future<void> _createNewProject() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateProjectScreen()),
    );
    if (created == true && mounted) {
      final provider = context.read<ProjectProvider>();
      if (provider.projectPath != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const EditorScreen()),
        );
      }
      _loadHistory();
    }
  }

  Future<void> _removeHistory(Project project) async {
    await ProjectHistoryService.instance.remove(project.path);
    await _loadHistory();
  }

  /// 登录入口（点击头像 / 右上角登录按钮）
  ///
  /// 已登录时直接进入账号页；未登录时弹出可选的登录方式。
  void _showLoginSheet() {
    final account = context.read<AccountProvider>();
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    if (account.isSignedIn || github.isSignedIn || gitee.isSignedIn) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AccountScreen()),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '登录 SLIPE',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle),
              title: const Text('SLIPE 账号'),
              subtitle: const Text('邮箱登录，跨设备同步设置'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('GitHub'),
              subtitle: const Text('授权后可直接创建仓库'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await github.signIn();
              },
            ),
            ListTile(
              leading: const Icon(Icons.code_off),
              title: const Text('Gitee'),
              subtitle: const Text('授权后可直接创建仓库'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await gitee.signIn();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除记录'),
        content: Text('从列表中移除「${project.name}」？\n（不会删除磁盘上的文件）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) await _removeHistory(project);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 首页按显示范围决定是否叠加背景图；显示时降低渐变不透明度让背景可见
    final settings = context.watch<SettingsProvider>().settings;
    final showBackground =
        AppBackground.shouldShow(settings, isIdeScreen: false);

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
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              children: [
                // 右上角入口：偏好设置 / SLIPE 账号（登录后隐藏登录按钮）
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '偏好设置',
                      icon: const Icon(Icons.tune),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                    ),
                    Consumer<AccountProvider>(
                      builder: (context, account, _) => Consumer2<
                          GitHubProvider, GiteeProvider>(
                        builder: (context, github, gitee, _) {
                          final signedIn = account.isSignedIn ||
                              github.isSignedIn ||
                              gitee.isSignedIn;
                          if (signedIn) return const SizedBox.shrink();
                          return IconButton(
                            tooltip: '登录',
                            icon: const Icon(Icons.login),
                            onPressed: _showLoginSheet,
                          );
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'SLIPE 账号',
                      icon: const Icon(Icons.manage_accounts),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AccountScreen(),
                        ),
                      ),
                    ),
                  ],
                ),

                // 头像 + 自定义标题（点击头像可登录）
                FadeTransition(
                  opacity: _logoFade,
                  child: Consumer<SettingsProvider>(
                    builder: (context, settingsProvider, _) {
                      final settings = settingsProvider.settings;
                      return Column(
                        children: [
                          GestureDetector(
                            onTap: _showLoginSheet,
                            child: _HomeAvatar(
                              avatarPath: settings.avatarPath,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            settings.homeTitle,
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
                ),
                const SizedBox(height: 12),

                // 随机语句（打字机效果，可在偏好设置中关闭）
                Consumer<SettingsProvider>(
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
                                color:
                                    isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                    );
                  },
                ),
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

                const SizedBox(height: 16),

                // 创建 / 打开 并排按钮
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.add,
                        label: '创建项目',
                        onTap: _createNewProject,
                        isDark: isDark,
                        primary: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.folder_open,
                        label: '打开项目',
                        onTap: _openExistingProject,
                        isDark: isDark,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        ),
      ),
      // 底部 Git 平台登录状态栏（GitHub / Gitee）
      bottomNavigationBar: const _GitStatusBar(),
    );
  }

  Widget _buildHistoryList(bool isDark) {
    if (_loadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_history.isEmpty) {
      return Center(
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
              '还没有项目\n点击下方按钮创建或打开一个吧',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _history.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _LastEditedCard(
              project: _history.first,
              isDark: isDark,
              onTap: () => _openProjectPath(
                _history.first.path,
                name: _history.first.name,
              ),
            ),
          );
        }
        final project = _history[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ProjectCard(
            project: project,
            isDark: isDark,
            onTap: () => _openProjectPath(project.path, name: project.name),
            onLongPress: () => _confirmRemove(project),
          ),
        );
      },
    );
  }
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
                      '上次编辑',
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
                '继续编辑',
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
      message: '点击登录 / 查看账号',
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
                  color: Colors.blueAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.folder,
                  color: Colors.blueAccent,
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
                      project.path,
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

/// 操作按钮（创建/打开）
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDark;
  final bool primary;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.isDark,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary
          ? Colors.blueAccent
          : (isDark ? const Color(0xFF2D2D30) : Colors.white),
      borderRadius: BorderRadius.circular(12),
      elevation: primary ? 4 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: primary ? Colors.white : Colors.blueAccent,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color:
                      primary ? Colors.white : (isDark ? Colors.white : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部 Git 平台登录状态栏（GitHub / Gitee 并排）
class _GitStatusBar extends StatelessWidget {
  const _GitStatusBar();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1B1D) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFDDDDDD),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Consumer<GitHubProvider>(
                  builder: (context, github, _) => _HostAuthTile(
                    icon: Icons.code,
                    label: 'GitHub',
                    color: isDark ? Colors.white : Colors.black87,
                    isDark: isDark,
                    signingIn:
                        github.status == GitHubAuthStatus.signingIn,
                    signedIn: github.isSignedIn,
                    login: github.user?.login,
                    avatarUrl: github.user?.avatarUrl,
                    onSignIn: () => github.signIn().then((ok) {
                      if (!ok && github.error != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(github.error!)),
                        );
                      }
                    }),
                    onSignOut: github.signOut,
                    onCancel: github.cancelSignIn,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Consumer<GiteeProvider>(
                  builder: (context, gitee, _) => _HostAuthTile(
                    icon: Icons.cloud,
                    label: 'Gitee',
                    color: const Color(0xFFC71D23),
                    isDark: isDark,
                    signingIn: gitee.status == GiteeAuthStatus.signingIn,
                    signedIn: gitee.isSignedIn,
                    login: gitee.user?.login,
                    avatarUrl: gitee.user?.avatarUrl,
                    onSignIn: () => gitee.signIn().then((ok) {
                      if (!ok && gitee.error != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(gitee.error!)),
                        );
                      }
                    }),
                    onSignOut: gitee.signOut,
                    onCancel: gitee.cancelSignIn,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个平台的登录状态小卡片
class _HostAuthTile extends StatelessWidget {
  const _HostAuthTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
    required this.signingIn,
    required this.signedIn,
    required this.onSignIn,
    required this.onSignOut,
    required this.onCancel,
    this.login,
    this.avatarUrl,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final bool signingIn;
  final bool signedIn;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onCancel;
  final String? login;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    if (signingIn) {
      // 授权中点击可取消（例如浏览器被拦截、用户中途返回时不会一直转圈）
      return _shell(
        GestureDetector(
          onTap: onCancel,
          child: Tooltip(
            message: '点击取消登录',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '登录 $label…（点击取消）',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (signedIn) {
      return _shell(
        Row(
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: color.withValues(alpha: 0.2),
              backgroundImage: (avatarUrl ?? '').isNotEmpty
                  ? NetworkImage(avatarUrl!)
                  : null,
              child: (avatarUrl ?? '').isEmpty
                  ? Icon(icon, size: 14, color: color)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '@${login ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: '退出 $label',
              icon: Icon(
                Icons.logout,
                size: 16,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
              onPressed: onSignOut,
            ),
          ],
        ),
      );
    }
    return _shell(
      SizedBox(
        width: double.infinity,
        child: TextButton(
          onPressed: onSignIn,
          style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(vertical: 8),
            visualDensity: VisualDensity.compact,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '登录 $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shell(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262628) : const Color(0xFFF3F5F7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: child,
    );
  }
}
