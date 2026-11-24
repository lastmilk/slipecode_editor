import 'package:flutter/material.dart';

import '../../services/command_registry.dart';
import 'desktop_title_bar.dart';

class DesktopMenuItemSpec {
  final String label;
  final VoidCallback? onSelected;
  final bool enabled;
  final ShortcutActivator? activator;
  final bool separatorBefore;

  const DesktopMenuItemSpec({
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.activator,
    this.separatorBefore = false,
  });
}

class DesktopMenuSpec {
  final String label;
  final List<DesktopMenuItemSpec> items;

  const DesktopMenuSpec({required this.label, required this.items});
}

/// 桌面菜单宿主：macOS 把菜单挂到系统菜单栏，Windows/Linux 渲染自绘标题栏。
///
/// Windows/Linux 不使用系统标题栏，而是由 [DesktopTitleBar] 自行绘制：
/// 最左侧是形态切换按钮，随后是菜单、项目名、搜索与窗口控件。
class DesktopMenuHost extends StatelessWidget {
  final List<DesktopMenuSpec> menus;
  final Widget child;

  /// 最左侧的品牌 / 形态切换按钮
  final Widget? leading;

  /// 项目名（显示在菜单右侧）
  final String title;

  /// 项目名前面的小图标
  final Widget? titleLeading;

  /// 搜索入口
  final Widget? search;

  /// 右侧自定义操作（在窗口控件之前）
  final List<Widget> actions;

  /// 「设置」入口
  final VoidCallback? settings;

  /// 点击标题（项目名）时的回调：多项目管理菜单
  final void Function(BuildContext anchor)? onProjectMenu;

  const DesktopMenuHost({
    super.key,
    required this.menus,
    required this.child,
    this.leading,
    this.title = '',
    this.titleLeading,
    this.search,
    this.actions = const [],
    this.settings,
    this.onProjectMenu,
  });

  @override
  Widget build(BuildContext context) {
    if (isMacDesktop) {
      return PlatformMenuBar(
        menus: [
          for (final menu in menus)
            PlatformMenu(
              label: menu.label,
              menus: [
                for (final item in menu.items)
                  PlatformMenuItem(
                    label: item.label,
                    onSelected: item.enabled ? item.onSelected : null,
                  ),
              ],
            ),
        ],
        child: child,
      );
    }
    return Column(
      children: [
        DesktopTitleBar(
          brand: leading ?? _defaultBrand(context),
          menus: _buildMenuButtons(context),
          title: title,
          titleLeading: titleLeading,
          search: search,
          actions: actions,
          onSettings: settings,
          onProjectMenu: onProjectMenu,
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _defaultBrand(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8),
      child: Icon(Icons.code, size: 18),
    );
  }

  List<Widget> _buildMenuButtons(BuildContext context) =>
      buildDesktopMenuButtons(context, menus);
}

/// 把菜单规格渲染成标题栏里的一排菜单按钮（供自绘标题栏复用）
List<Widget> buildDesktopMenuButtons(
  BuildContext context,
  List<DesktopMenuSpec> menus,
) {
  final theme = Theme.of(context);
  return [
    for (final menu in menus)
      MenuBar(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
        children: [
          SubmenuButton(
            menuChildren: _materialMenuItems(menu.items),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(menu.label, style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
  ];
}

List<Widget> _materialMenuItems(List<DesktopMenuItemSpec> items) {
  final result = <Widget>[];
  for (final item in items) {
    if (item.separatorBefore) {
      result.add(const Divider(height: 8));
    }
    result.add(
      MenuItemButton(
        onPressed: item.enabled ? item.onSelected : null,
        shortcut: item.activator is MenuSerializableShortcut
            ? item.activator as MenuSerializableShortcut
            : null,
        child: Text(item.label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
  return result;
}
