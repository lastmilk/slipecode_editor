import 'package:flutter/material.dart';

import 'scene_tokens.dart';

/// 场景大厅 Bento 网格。
///
/// 宽屏保持两行 flex 布局：上排 flex 3（Coding 11 : Video 7），
/// 下排 flex 2（Auto 10 : Text 7 : Chat 7）；
/// 移动端（宽度 < 900）改为单列堆叠，避免拥挤溢出。
class SceneBentoGrid extends StatelessWidget {
  const SceneBentoGrid({
    super.key,
    required this.coding,
    required this.video,
    required this.auto,
    required this.text,
    required this.chat,
    this.gap = SceneTokens.gap,
  });

  final Widget coding;
  final Widget video;
  final Widget auto;
  final Widget text;
  final Widget chat;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 单列布局：移动端按阅读顺序堆叠，可滚动查看全部场景。
        if (width < 900) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              SizedBox(height: 240, child: coding),
              const SizedBox(height: 12),
              SizedBox(height: 200, child: video),
              const SizedBox(height: 12),
              SizedBox(height: 200, child: auto),
              const SizedBox(height: 12),
              SizedBox(height: 200, child: text),
              const SizedBox(height: 12),
              SizedBox(height: 200, child: chat),
            ],
          );
        }

        // 900~1100 用更紧凑的 12 间距，宽屏沿用令牌间距。
        final spacing = width < 1100 ? 12.0 : gap;
        return Column(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 11, child: coding),
                  SizedBox(width: spacing),
                  Expanded(flex: 7, child: video),
                ],
              ),
            ),
            SizedBox(height: spacing),
            Expanded(
              flex: 2,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 10, child: auto),
                  SizedBox(width: spacing),
                  Expanded(flex: 7, child: text),
                  SizedBox(width: spacing),
                  Expanded(flex: 7, child: chat),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
