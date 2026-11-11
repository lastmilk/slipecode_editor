import 'package:flutter/material.dart';

import 'project_creation_flow.dart';

/// 底部导航的四个主页面
enum MainTab { home, community, docs, my }

/// 主界面底栏（参考贝壳找房的结构：四个文字入口 + 中间凸起的圆形按钮）
///
/// 中间的「＋」对应新建项目；在社区页会自动变成「发帖」图标。
class MainBottomNav extends StatelessWidget {
  const MainBottomNav({
    super.key,
    required this.current,
    required this.onSelect,
    this.onCenterTap,
    this.centerIcon,
    this.centerLabel,
  });

  /// 当前所在主页面
  final MainTab current;

  /// 点击四个主入口时回调（由 MainShell 负责切换页面）
  final ValueChanged<MainTab> onSelect;

  /// 中间按钮的点击行为（不传则默认打开新建项目）
  final VoidCallback? onCenterTap;

  /// 中间按钮图标（不传则默认「＋」）
  final IconData? centerIcon;

  /// 中间按钮下方文案（不传则默认「新建」）
  final String? centerLabel;

  static const _items = <MainTab, (String, IconData, IconData)>{
    MainTab.home: ('首页', Icons.home_outlined, Icons.home_rounded),
    MainTab.community: ('社区', Icons.forum_outlined, Icons.forum_rounded),
    MainTab.docs: ('文档', Icons.menu_book_outlined, Icons.menu_book_rounded),
    MainTab.my: ('我的', Icons.person_outline_rounded, Icons.person_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final background = isDark ? const Color(0xFF1B1B1D) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: background,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFEDEEF0),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                children: [
                  _tab(MainTab.home, primary, isDark),
                  _tab(MainTab.community, primary, isDark),
                  const SizedBox(width: 78),
                  _tab(MainTab.docs, primary, isDark),
                  _tab(MainTab.my, primary, isDark),
                ],
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Transform.translate(
                  offset: const Offset(0, -16),
                  child: _centerButton(context, primary, isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(
    MainTab tab,
    Color primary,
    bool isDark,
  ) {
    final (label, outlined, filled) = _items[tab]!;
    final selected = current == tab;
    final color = selected
        ? primary
        : (isDark ? Colors.white60 : const Color(0xFF8A8F99));

    return Expanded(
      child: InkWell(
        onTap: selected ? null : () => onSelect(tab),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? filled : outlined, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _centerButton(BuildContext context, Color primary, bool isDark) {
    final label = centerLabel ??
        (current == MainTab.community ? '发帖' : '新建');
    final icon = centerIcon ??
        (current == MainTab.community ? Icons.edit_outlined : Icons.add);

    return GestureDetector(
      onTap: onCenterTap ?? () => showCreateProjectFlow(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [primary, Color.lerp(primary, Colors.black, 0.18)!],
              ),
              border: Border.all(
                color: isDark ? const Color(0xFF1B1B1D) : Colors.white,
                width: 4,
              ),
              boxShadow: [
                BoxShadow(
                  color: primary.withValues(alpha: 0.32),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : const Color(0xFF4A4F57),
            ),
          ),
        ],
      ),
    );
  }
}
