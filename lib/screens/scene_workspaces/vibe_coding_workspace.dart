import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../models/scene.dart';
import '../../services/desktop_platform.dart';
import '../../services/editor_process_service.dart';
import '../../services/scene_registry.dart';
import '../../services/scene_session_service.dart';
import '../../widgets/scene/glass_card.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import '../editor_screen.dart';
import 'vibe_coding_wizard.dart';
import 'workspace_shell.dart';

/// VibeCoding 工作台。
///
/// 用统一的工作台外壳承载两种创建范式：
/// - 新范式：设计稿 + 三层 Payload + Loader 项目；
/// - 传统范式：Flutter / Android / Node / Web 等内置模板直接起步。
/// 表单由 [VibeCodingWizard] 按场景体系重新实现，
/// 创建成功后的打开项目与关闭工作台逻辑保持不变。
class VibeCodingWorkspace extends StatefulWidget {
  const VibeCodingWorkspace({
    super.key,
    required this.selection,
    this.draft,
    this.initialDraftId,
  });

  final SceneSelection selection;
  final SceneDraft? draft;

  /// 从「我的设计稿」直接创建时预选的设计稿 id。
  final String? initialDraftId;

  @override
  State<VibeCodingWorkspace> createState() => _VibeCodingWorkspaceState();
}

class _VibeCodingWorkspaceState extends State<VibeCodingWorkspace> {
  static const String _classicParadigm = 'paradigm_classic';

  late VibeCodingParadigm _paradigm;

  @override
  void initState() {
    super.initState();
    _paradigm = widget.selection.typeId == _classicParadigm
        ? VibeCodingParadigm.classic
        : VibeCodingParadigm.newParadigm;
  }

  SceneDefinition? get _scene => SceneRegistry.byId(widget.selection.sceneId);

  String get _subtitle {
    final scene = _scene;
    if (scene == null) return '选择范式后创建项目';
    final element = scene.elementById(widget.selection.elementId ?? '');
    final type = scene.typeById(widget.selection.typeId ?? '');
    final parts = <String>[
      if (element != null) element.name,
      if (type != null) type.name,
    ];
    return parts.isEmpty ? '选择范式后创建项目' : parts.join(' · ');
  }

  bool get _isNew => _paradigm == VibeCodingParadigm.newParadigm;

  /// 创建成功后打开项目：桌面端拉起独立 Editor 进程，移动端同进程压栈。
  Future<void> _handleCreated(String targetPath) async {
    if (!mounted) return;
    try {
      if (DesktopPlatform.isDesktop) {
        await EditorProcessService.instance.openProject(
          targetPath,
          projectName: p.basename(targetPath),
        );
      } else {
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const EditorScreen()));
      }
    } catch (e) {
      debugPrint('打开新项目失败：$e');
    }
    if (!mounted) return;
    // 关闭工作台，回到场景大厅；项目列表由调用方刷新。
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final accent = _scene?.accent ?? const Color(0xFF00F07A);
    final narrow = MediaQuery.sizeOf(context).width < 900;

    return WorkspaceShell(
      title: 'VibeCoding',
      subtitle: _subtitle,
      accent: accent,
      symbol: SceneSymbolKind.coding,
      statusLabel: _isNew ? '新范式' : '传统范式',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildParadigmSwitch(context, palette, accent, narrow),
          const SizedBox(height: 14),
          Expanded(
            child: GlassCard(
              radius: SceneTokens.radiusMedium,
              glow: true,
              accent: accent,
              padding: EdgeInsets.all(narrow ? 14 : 20),
              child: AnimatedSwitcher(
                duration: SceneTokens.durationPage,
                switchInCurve: SceneTokens.curve,
                child: _isNew
                    ? VibeCodingWizard(
                        key: const ValueKey('loader'),
                        paradigm: VibeCodingParadigm.newParadigm,
                        initialDraftId: widget.initialDraftId,
                        onCreated: _handleCreated,
                      )
                    : VibeCodingWizard(
                        key: const ValueKey('classic'),
                        paradigm: VibeCodingParadigm.classic,
                        onCreated: _handleCreated,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 范式切换：两张大按钮，不用小控件。
  Widget _buildParadigmSwitch(
    BuildContext context,
    ScenePalette palette,
    Color accent,
    bool narrow,
  ) {
    final items = const <_ParadigmOption>[
      _ParadigmOption(
        paradigm: VibeCodingParadigm.newParadigm,
        title: '新范式',
        description: '设计稿 + 三层 Payload，交给 AI 生成完整项目',
        icon: Icons.auto_awesome_rounded,
      ),
      _ParadigmOption(
        paradigm: VibeCodingParadigm.classic,
        title: '传统范式',
        description: 'Flutter / Android / Node / Web 内置模板直接起步',
        icon: Icons.dashboard_customize_rounded,
      ),
    ];

    if (narrow) {
      return Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _buildOption(context, palette, accent, items[i]),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: _buildOption(context, palette, accent, items[i])),
        ],
      ],
    );
  }

  Widget _buildOption(
    BuildContext context,
    ScenePalette palette,
    Color accent,
    _ParadigmOption option,
  ) {
    final selected = _paradigm == option.paradigm;
    return GlassCard(
      radius: SceneTokens.radiusSmall,
      glow: selected,
      accent: accent,
      onTap: () => setState(() => _paradigm = option.paradigm),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      semanticLabel: option.title,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: palette.isDark ? 0.18 : 0.14)
                  : palette.inputFill,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              option.icon,
              size: 20,
              color: selected ? accent : palette.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  option.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    15,
                    color: selected
                        ? palette.textPrimary
                        : palette.textSecondary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  option.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneCaption(
                    11.5,
                    color: palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check_circle_rounded, size: 18, color: accent),
        ],
      ),
    );
  }
}

class _ParadigmOption {
  const _ParadigmOption({
    required this.paradigm,
    required this.title,
    required this.description,
    required this.icon,
  });

  final VibeCodingParadigm paradigm;
  final String title;
  final String description;
  final IconData icon;
}
