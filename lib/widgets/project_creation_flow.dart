import 'package:flutter/material.dart';

import '../screens/scene_hall_screen.dart';

/// 新建项目流程（底栏中间的「＋」、品牌菜单、首页入口共用）。
///
/// 所有平台统一进入场景向导（[SceneHallScreen]）：
/// 场景 → 细分元素 → 项目类型 都在同一页面内完成，
/// 不再保留旧的底部弹窗与独立创建页入口。
Future<void> showCreateProjectFlow(
  BuildContext context, {
  VoidCallback? onDone,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const SceneHallScreen()),
  );
  onDone?.call();
}
