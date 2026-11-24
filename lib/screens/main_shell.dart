import 'package:flutter/material.dart';

import '../services/desktop_platform.dart';
import '../widgets/desktop/desktop_dialogs.dart';
import '../widgets/desktop/desktop_title_bar.dart';
import '../widgets/main_bottom_nav.dart';
import '../widgets/project_creation_flow.dart';
import 'community_screen.dart';
import 'docs_screen.dart';
import 'home_screen.dart';
import 'my_screen.dart';

/// 主界面外壳：四个主页面 + 共享导航
///
/// 移动端使用底栏；桌面端使用左侧竖向导航，整体呈现为「SLIPE Hub」
/// （项目中心），打开具体项目后进入独立的「SLIPE Editor」窗口栈。
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final PageController _controller = PageController();
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<CommunityScreenState> _communityKey =
      GlobalKey<CommunityScreenState>();

  int _index = 0;

  static const _tabs = MainTab.values;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(MainTab tab) {
    final target = _tabs.indexOf(tab);
    if (target == _index) return;
    setState(() => _index = target);
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  void _centerAction() {
    if (_index == 1) {
      _communityKey.currentState?.compose();
      return;
    }
    showCreateProjectFlow(
      context,
      onDone: () => _homeKey.currentState?.reloadHistory(),
    );
  }

  void _openSettings() {
    showSettingsDialog(context);
  }

  /// 标题栏最左侧按钮：点击展开「新建 / 打开 / 设置」切换菜单
  Widget _buildBrandButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: 'SLIPE',
      offset: const Offset(0, 34),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        switch (value) {
          case 'new':
            _centerAction();
          case 'settings':
            _openSettings();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'new', child: Text('新建项目')),
        PopupMenuItem(value: 'settings', child: Text('偏好设置')),
      ],
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset('assets/logo/slipe_logo.jpg', fit: BoxFit.cover),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) {
          _select(MainTab.home);
        }
      },
      child: Scaffold(
        body: DesktopPlatform.isDesktop
            ? Column(
                children: [
                  // 自绘标题栏（系统标题栏已隐藏）
                  DesktopTitleBar(
                    brand: _buildBrandButton(),
                    menus: const [],
                    title: 'SLIPE Hub',
                    titleLeading: const Icon(Icons.grid_view_rounded, size: 13),
                    onSettings: _openSettings,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        _buildDesktopRail(),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: PageView(
                            controller: _controller,
                            physics: const NeverScrollableScrollPhysics(),
                            onPageChanged: (value) {
                              if (value != _index) {
                                setState(() => _index = value);
                              }
                            },
                            children: _pages(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (value) {
                  if (value != _index) setState(() => _index = value);
                },
                children: _pages(),
              ),
        bottomNavigationBar: DesktopPlatform.isDesktop
            ? null
            : MainBottomNav(
                current: _tabs[_index],
                onSelect: _select,
                onCenterTap: _centerAction,
                centerIcon: _index == 1 ? Icons.edit_outlined : null,
                centerLabel: _index == 1 ? '发帖' : null,
              ),
      ),
    );
  }

  List<Widget> _pages() => [
    _CardPage(
      controller: _controller,
      index: 0,
      child: HomeScreen(key: _homeKey),
    ),
    _CardPage(
      controller: _controller,
      index: 1,
      child: CommunityScreen(key: _communityKey),
    ),
    _CardPage(controller: _controller, index: 2, child: const DocsScreen()),
    _CardPage(controller: _controller, index: 3, child: const MyScreen()),
  ];

  /// 桌面端左侧导航（SLIPE Hub）
  Widget _buildDesktopRail() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: 88,
      color: isDark ? const Color(0xFF17171A) : const Color(0xFFF7F7F9),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 14),
            // 品牌标识
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/logo/slipe_logo.jpg',
                width: 34,
                height: 34,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'HUB',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ),
            const SizedBox(height: 18),
            for (var i = 0; i < _tabs.length; i++)
              _buildRailItem(index: i, isDark: isDark, accent: accent),
            const Spacer(),
            IconButton(
              tooltip: '新建项目',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _centerAction,
            ),
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.tune),
              onPressed: () => showSettingsDialog(context),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildRailItem({
    required int index,
    required bool isDark,
    required Color accent,
  }) {
    final selected = index == _index;
    final tab = _tabs[index];
    final labels = const ['Hub', '社区', '文档', '我的'];
    final icons = const [
      Icons.grid_view_rounded,
      Icons.forum_outlined,
      Icons.menu_book_outlined,
      Icons.person_outline,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _select(tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Icon(
                icons[index],
                size: 20,
                color: selected
                    ? accent
                    : (isDark ? Colors.white54 : Colors.black45),
              ),
              const SizedBox(height: 4),
              Text(
                labels[index],
                style: TextStyle(
                  fontSize: 10,
                  color: selected
                      ? accent
                      : (isDark ? Colors.white54 : Colors.black45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单页的卡片过渡：离当前页越远，缩放与透明度越低
class _CardPage extends StatelessWidget {
  const _CardPage({
    required this.controller,
    required this.index,
    required this.child,
  });

  final PageController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        double page = index.toDouble();
        if (controller.hasClients && controller.position.haveDimensions) {
          page = controller.page ?? page;
        }
        final distance = (page - index).abs().clamp(0.0, 1.0);
        final scale = 1 - 0.045 * distance;
        final opacity = 1 - 0.28 * distance;
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: _KeepAlive(child: child),
    );
  }
}

/// 保留页面状态，避免切换 Tab 后列表位置与输入内容丢失
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
