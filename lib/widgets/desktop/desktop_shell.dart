import 'package:flutter/material.dart';

import 'activity_bar.dart';
import 'menu_bar.dart';
import 'resizable_split.dart';

/// 桌面编辑器外壳：菜单栏 + 活动栏 + 可拖拽侧边栏 + 编辑区 + 底部面板
/// + 常驻 AI 侧边栏。
///
/// AI 是一等公民：IDE 布局在右侧，SOLO 布局在左侧。
/// SOLO 布局下活动栏与文件侧边栏不隐藏，而是镜像到窗口右侧，
/// 与左侧 AI 面板形成「AI | 代码 | 文件」的三栏结构。
///
/// 所有位移动画都由同一个 [AnimationController] 驱动，宽度均为显式计算，
/// 不使用 [AnimatedSize] 之类依赖子级自然尺寸的隐式动画，避免尺寸反馈
/// 导致动画永不收敛（表现为持续重绘、输入迟滞）。
class DesktopShell extends StatefulWidget {
  final List<DesktopMenuSpec> menus;
  final Widget activityBar;
  final Widget? sidebar;
  final bool sidebarVisible;
  final double sidebarWidth;
  final ValueChanged<double> onSidebarResize;
  final VoidCallback? onSidebarReset;
  final Widget editor;
  final Widget? bottomPanel;
  final bool panelVisible;
  final double panelHeight;
  final ValueChanged<double> onPanelResize;
  final VoidCallback? onPanelReset;
  final Widget statusBar;

  /// 常驻 AI 面板（IDE 在右、SOLO 在左）
  final Widget? aiPanel;
  final bool aiPanelOnLeft;
  final double aiPanelWidth;
  final ValueChanged<double>? onAiResize;
  final VoidCallback? onAiReset;

  /// 活动栏与文件侧边栏是否显示
  final bool showActivityBar;

  /// 活动栏与文件侧边栏是否镜像到右侧（SOLO 布局）
  final bool sidebarOnRight;

  /// 自绘标题栏内容：最左侧形态切换按钮 / 项目名 / 搜索 / 右侧操作
  final Widget? titleBarLeading;
  final String projectName;
  final Widget? titleLeading;
  final Widget? titleBarSearch;
  final List<Widget> titleBarActions;
  final VoidCallback? titleBarSettings;

  /// 点击标题栏项目名时的回调（多项目切换菜单），参数为标题的 context
  final void Function(BuildContext anchor)? onProjectMenu;

  const DesktopShell({
    super.key,
    required this.menus,
    required this.activityBar,
    required this.sidebar,
    required this.sidebarVisible,
    required this.sidebarWidth,
    required this.onSidebarResize,
    required this.editor,
    required this.bottomPanel,
    required this.panelVisible,
    required this.panelHeight,
    required this.onPanelResize,
    required this.statusBar,
    this.onSidebarReset,
    this.onPanelReset,
    this.aiPanel,
    this.aiPanelOnLeft = false,
    this.aiPanelWidth = 360,
    this.onAiResize,
    this.onAiReset,
    this.showActivityBar = true,
    this.sidebarOnRight = false,
    this.titleBarLeading,
    this.projectName = '',
    this.titleLeading,
    this.titleBarSearch,
    this.titleBarActions = const [],
    this.titleBarSettings,
    this.onProjectMenu,
  });

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 320);

  /// 0：AI 在左（SOLO）；1：AI 在右（IDE）
  late final AnimationController _side = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.aiPanelOnLeft ? 0 : 1,
  );

  @override
  void didUpdateWidget(covariant DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aiPanelOnLeft != widget.aiPanelOnLeft ||
        oldWidget.sidebarOnRight != widget.sidebarOnRight) {
      _side.animateTo(
        widget.aiPanelOnLeft ? 0 : 1,
        duration: _duration,
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _side.dispose();
    super.dispose();
  }

  /// 活动栏 + 文件侧边栏的自然宽度
  double get _chromeWidth {
    if (!widget.showActivityBar) return 0;
    var width = ActivityBar.width;
    if (widget.sidebarVisible && widget.sidebar != null) {
      width += widget.sidebarWidth + 5; // 侧边栏 + 分隔条
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    return DesktopMenuHost(
      menus: widget.menus,
      leading: widget.titleBarLeading,
      title: widget.projectName,
      titleLeading: widget.titleLeading,
      search: widget.titleBarSearch,
      actions: widget.titleBarActions,
      settings: widget.titleBarSettings,
      onProjectMenu: widget.onProjectMenu,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: _side,
            builder: (context, _) {
              final t = _side.value;
              final panelWidth = widget.aiPanelWidth;
              final aiLeftWidth = (1 - t) * panelWidth;
              final aiRightWidth = t * panelWidth;
              final chromeOnRight = widget.sidebarOnRight;

              return Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (aiLeftWidth > 0.5) ...[
                        SizedBox(width: aiLeftWidth),
                        ResizableSplit(
                          axis: Axis.horizontal,
                          onDelta: (delta) =>
                              widget.onAiResize?.call(-delta),
                          onReset: widget.onAiReset,
                        ),
                      ],
                      if (!chromeOnRight) _sideSlot(onRight: false),
                      Expanded(child: _buildEditorColumn()),
                      if (chromeOnRight) _sideSlot(onRight: true),
                      if (aiRightWidth > 0.5) ...[
                        ResizableSplit(
                          axis: Axis.horizontal,
                          onDelta: (delta) =>
                              widget.onAiResize?.call(delta),
                          onReset: widget.onAiReset,
                        ),
                        SizedBox(width: aiRightWidth),
                      ],
                    ],
                  ),
                  if (widget.aiPanel != null)
                    Positioned(
                      left: t * (constraints.maxWidth - panelWidth),
                      top: 0,
                      bottom: 0,
                      width: panelWidth,
                      child: RepaintBoundary(child: widget.aiPanel!),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 侧栏槽位：固定自然宽度（不做尺寸动画，避免布局反馈）
  Widget _sideSlot({required bool onRight}) {
    if (!widget.showActivityBar) return const SizedBox.shrink();
    return SizedBox(
      width: _chromeWidth,
      child: _buildChrome(onRight: onRight),
    );
  }

  /// 活动栏 + 文件侧边栏（[onRight] 时镜像到右侧，顺序反转）
  Widget _buildChrome({required bool onRight}) {
    if (!widget.showActivityBar) return const SizedBox.shrink();
    final showSidebar = widget.sidebarVisible && widget.sidebar != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onRight) ...[
          if (showSidebar) ...[
            ResizableSplit(
              axis: Axis.horizontal,
              onDelta: (delta) => widget.onSidebarResize(-delta),
              onReset: widget.onSidebarReset,
            ),
            SizedBox(
              width: widget.sidebarWidth,
              child: RepaintBoundary(child: widget.sidebar),
            ),
          ],
          widget.activityBar,
        ] else ...[
          widget.activityBar,
          if (showSidebar) ...[
            SizedBox(
              width: widget.sidebarWidth,
              child: RepaintBoundary(child: widget.sidebar),
            ),
            ResizableSplit(
              axis: Axis.horizontal,
              onDelta: widget.onSidebarResize,
              onReset: widget.onSidebarReset,
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildEditorColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: RepaintBoundary(child: widget.editor)),
        if (widget.panelVisible && widget.bottomPanel != null) ...[
          ResizableSplit(
            axis: Axis.vertical,
            onDelta: widget.onPanelResize,
            onReset: widget.onPanelReset,
          ),
          SizedBox(height: widget.panelHeight, child: widget.bottomPanel),
        ],
      ],
    );
  }
}
