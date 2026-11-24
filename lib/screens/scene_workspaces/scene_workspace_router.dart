import 'package:flutter/material.dart';

import '../../models/scene.dart';
import '../../services/scene_session_service.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import 'auto_workspace.dart';
import 'chat_workspace.dart';
import 'text_workspace.dart';
import 'vibe_coding_workspace.dart';
import 'vibe_video_workspace.dart';

/// 按所选场景构建场景工作台。
///
/// VibeCoding 会进入统一工作台，并在其中完整承载原有创建页面的能力；
/// 未知场景回退到提示页，避免白屏。
Widget buildSceneWorkspace(SceneSelection selection, {SceneDraft? draft}) {
  return switch (selection.sceneId) {
    'vibe_coding' => VibeCodingWorkspace(selection: selection, draft: draft),
    'vibe_video' => VibeVideoWorkspace(selection: selection, draft: draft),
    'auto' => AutoWorkspace(selection: selection, draft: draft),
    'text' => TextWorkspace(selection: selection, draft: draft),
    'chat' => ChatWorkspace(selection: selection, draft: draft),
    _ => _UnknownScenePage(sceneId: selection.sceneId),
  };
}

/// 未知场景回退页。
class _UnknownScenePage extends StatelessWidget {
  const _UnknownScenePage({required this.sceneId});

  final String sceneId;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Scaffold(
      backgroundColor: palette.bgTop,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.backgroundGradient),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.travel_explore_rounded,
                size: 40,
                color: palette.textTertiary,
              ),
              const SizedBox(height: 16),
              Text(
                '未找到对应场景',
                style: SceneTokens.sceneTitle(
                  20,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '场景标识：$sceneId\n请从场景大厅重新进入。',
                textAlign: TextAlign.center,
                style: SceneTokens.sceneCaption(
                  12,
                  color: palette.textTertiary,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 40,
                child: FilledButton(
                  onPressed: () => Navigator.maybePop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.glassFillStrong,
                    foregroundColor: palette.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    '返回大厅',
                    style: TextStyle(fontSize: 12.5),
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
