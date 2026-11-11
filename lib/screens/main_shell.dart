import 'package:flutter/material.dart';

import '../widgets/main_bottom_nav.dart';
import '../widgets/project_creation_flow.dart';
import 'community_screen.dart';
import 'docs_screen.dart';
import 'home_screen.dart';
import 'my_screen.dart';

/// 主界面外壳：四个主页面 + 共享底栏
///
/// 使用 PageView 承载页面，切换时整页横向滑动并叠加轻微缩放/淡入，
/// 形成类似「卡片切页」的平滑过渡；页面状态由 KeepAlive 保留。
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
        body: PageView(
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (value) {
            if (value != _index) setState(() => _index = value);
          },
          children: [
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
            _CardPage(
              controller: _controller,
              index: 2,
              child: const DocsScreen(),
            ),
            _CardPage(
              controller: _controller,
              index: 3,
              child: const MyScreen(),
            ),
          ],
        ),
        bottomNavigationBar: MainBottomNav(
          current: _tabs[_index],
          onSelect: _select,
          onCenterTap: _centerAction,
          centerIcon:
              _index == 1 ? Icons.edit_outlined : null,
          centerLabel: _index == 1 ? '发帖' : null,
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
