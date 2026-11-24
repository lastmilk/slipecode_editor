import 'package:flutter/material.dart';

import 'glass_card.dart';
import 'scene_palette.dart';
import 'scene_tokens.dart';

/// 场景页面外壳：主题渐变背景 + 可选背景符号 + 顶部返回栏 + 内容区。
///
/// 大厅与三级流程页可复用，保证背景与边距统一；
/// 边距随窗口宽度自适应，兼顾移动端。
class ScenePageScaffold extends StatelessWidget {
  const ScenePageScaffold({
    super.key,
    required this.child,
    this.onBack,
    this.title,
    this.trailing,
    this.backgrounds,
    this.accent,
  });

  final Widget child;
  final VoidCallback? onBack;
  final String? title;
  final Widget? trailing;

  /// 背景符号层，从下到上依次铺满页面。
  final List<Widget>? backgrounds;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    // 大屏 48，中屏 28，移动端 18；顶部返回栏同步收紧。
    final pagePadding = width < 700
        ? 18.0
        : (width < 1100 ? 28.0 : SceneTokens.pagePadding);
    final topPadding = width < 700 ? 14.0 : (width < 1100 ? 18.0 : 24.0);

    final hasBackgrounds = backgrounds != null && backgrounds!.isNotEmpty;
    return Scaffold(
      backgroundColor: palette.bgTop,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.backgroundGradient),
        child: Stack(
          children: [
            if (hasBackgrounds)
              Positioned.fill(
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      for (final background in backgrounds!)
                        Positioned.fill(child: background),
                    ],
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      pagePadding,
                      topPadding,
                      pagePadding,
                      0,
                    ),
                    child: Row(
                      children: [
                        if (onBack != null) ...[
                          GlassCard(
                            onTap: onBack,
                            accent: accent,
                            radius: 12,
                            padding: EdgeInsets.zero,
                            glow: false,
                            semanticLabel: '返回',
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: Icon(
                                Icons.arrow_back_rounded,
                                size: 18,
                                color: palette.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                        ],
                        if (title != null)
                          Expanded(
                            child: Text(
                              title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SceneTokens.sceneTitle(
                                18,
                                color: palette.textPrimary,
                              ),
                            ),
                          )
                        else
                          const Spacer(),
                        ?trailing,
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(pagePadding),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
