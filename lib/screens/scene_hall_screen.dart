import 'package:flutter/material.dart';

import '../models/scene.dart';
import '../services/resource_download_service.dart';
import '../services/scene_registry.dart';
import '../services/scene_session_service.dart';
import '../widgets/scene/bento_grid.dart';
import '../widgets/scene/glass_card.dart';
import '../widgets/scene/resource_download.dart';
import '../widgets/scene/scene_backdrop.dart';
import '../widgets/scene/scene_option_grid.dart';
import '../widgets/scene/scene_page_scaffold.dart';
import '../widgets/scene/scene_palette.dart';
import '../widgets/scene/scene_tokens.dart';
import '../widgets/scene/step_indicator.dart';
import 'scene_workspaces/scene_workspace_router.dart';

/// 场景向导（唯一入口）：场景大厅 + 细分元素 + 项目类型。
///
/// 大厅与后续选择合并在同一页面内完成，避免出现两份「场景选择」界面：
/// - 第 0 步：Bento 场景大厅；
/// - 第 1 步：选择项目细分元素（产出形态）；
/// - 第 2 步：选择项目类型（范式 / 栈 / 模板）。
class SceneHallScreen extends StatefulWidget {
  const SceneHallScreen({super.key});

  @override
  State<SceneHallScreen> createState() => _SceneHallScreenState();
}

class _SceneHallScreenState extends State<SceneHallScreen>
    with SingleTickerProviderStateMixin {
  /// 入场 stagger 控制器（900ms）。
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 上次使用的场景 id，用于卡片「上次使用」徽标。
  String? _lastSceneId;

  /// 上次的完整选择，用于进入同场景时预选细分元素与项目类型。
  SceneSelection? _lastSelection;

  /// 本次会话是否已弹出过首次资源下载提示（避免返回大厅时重复弹出）。
  static bool _resourcePromptShown = false;

  static const Map<String, String> _slotTags = {
    'vibe_coding': '主场景',
    'vibe_video': '视频',
    'auto': '自动化',
    'text': '文档',
    'chat': '角色对话',
  };

  // ---------------- 向导状态 ----------------

  int _step = 0;
  String? _sceneId;
  String? _elementId;
  String? _typeId;
  bool _submitting = false;

  SceneDefinition? get _scene =>
      _sceneId == null ? null : SceneRegistry.byId(_sceneId!);

  SceneElement? get _element {
    final scene = _scene;
    if (scene == null || _elementId == null) return null;
    return scene.elementById(_elementId!);
  }

  Color get _accent => _scene?.accent ?? SceneRegistry.scenes.first.accent;

  SceneSelection? get _selection => _sceneId == null
      ? null
      : SceneSelection(
          sceneId: _sceneId!,
          elementId: _elementId,
          typeId: _typeId,
        );

  bool get _canContinue => switch (_step) {
        0 => _sceneId != null,
        1 => _elementId != null,
        _ => _typeId != null,
      };

  String get _stepTitle => switch (_step) {
        0 => '你的场景',
        1 => '它在产出什么',
        _ => '选择实现方式',
      };

  String get _stepSubtitle => switch (_step) {
        0 => '先选一个你最想完成的事。',
        1 => _scene == null ? '选择这次的产出形态。' : '${_scene!.name} 这次要交付什么？',
        _ => _element == null
            ? '挑一个落地方式，马上开始。'
            : '为「${_element!.name}」选择实现方式。',
      };

  @override
  void initState() {
    super.initState();
    _entrance.forward();
    _loadLastSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptResources());
  }

  /// 首次进入时检查按需资源，缺失则提示下载（每个会话仅一次）。
  Future<void> _maybePromptResources() async {
    final service = ResourceDownloadService.instance;
    await service.ensureLoaded();
    if (!service.enabled) return;
    if (!mounted || _resourcePromptShown) return;
    final missing = service.missing;
    if (missing.isEmpty) return;
    _resourcePromptShown = true;
    await showResourceDownloadPrompt(
      context,
      resources: missing,
      firstLaunch: true,
    );
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _loadLastSelection() async {
    final last = await SceneSessionService.instance.loadLastSelection();
    if (!mounted || last == null) return;
    if (SceneRegistry.byId(last.sceneId) == null) return;
    setState(() {
      _lastSceneId = last.sceneId;
      _lastSelection = last;
    });
  }

  /// 每张卡的入场动画：依次错峰出现。
  ///
  /// 移动端单列布局只保留淡入，避免纵向位移过大。
  Widget _animated(int index, Widget child, {required bool slide}) {
    final start = index * 0.11;
    final end = (start + 0.5).clamp(0.0, 1.0).toDouble();
    final curved = CurvedAnimation(
      parent: _entrance,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    if (!slide) {
      return FadeTransition(opacity: curved, child: child);
    }
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  // ---------------- 向导交互 ----------------

  /// 选中场景后直接进入细分元素步骤；同场景时沿用上次选择。
  void _selectScene(SceneDefinition scene) {
    final last = _lastSelection;
    String? elementId;
    String? typeId;
    if (last != null && last.sceneId == scene.id) {
      final lastElement = last.elementId == null
          ? null
          : scene.elementById(last.elementId!);
      if (lastElement != null) {
        elementId = lastElement.id;
        final lastType = last.typeId == null
            ? null
            : _findType(scene, lastElement.id, last.typeId!);
        typeId = lastType?.id;
      }
    }
    setState(() {
      _sceneId = scene.id;
      _elementId = elementId;
      _typeId = typeId;
      _step = 1;
    });
  }

  SceneProjectType? _findType(
    SceneDefinition scene,
    String elementId,
    String typeId,
  ) {
    for (final type in scene.typesForElement(elementId)) {
      if (type.id == typeId) return type;
    }
    return null;
  }

  void _selectElement(SceneElement element) {
    setState(() {
      _elementId = element.id;
      _typeId = null;
      _step = 2;
    });
  }

  void _selectType(SceneProjectType type) {
    setState(() => _typeId = type.id);
  }

  void _handleBack() {
    if (_step > 0) {
      setState(() => _step -= 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _goNext() {
    if (!_canContinue) return;
    if (_step < 2) {
      setState(() => _step += 1);
    } else {
      _finish();
    }
  }

  /// 完成选择：记忆 → 创建/恢复草稿 → 进入工作台。
  Future<void> _finish() async {
    final selection = _selection;
    final scene = _scene;
    if (selection == null || scene == null || !selection.isComplete) return;
    if (_submitting) return;

    setState(() => _submitting = true);
    await SceneSessionService.instance.saveLastSelection(selection);
    if (!mounted) return;

    SceneDraft? draft;
    try {
      // 优先恢复同一组合的历史草稿，保证重启后工作台内容仍在。
      final drafts = await SceneSessionService.instance.listDrafts();
      draft = _resumableDraft(drafts, selection) ??
          await SceneSessionService.instance.createDraft(selection);
    } catch (e) {
      // 草稿写入失败不阻塞工作台：降级为无草稿进入
      debugPrint('创建场景草稿失败，将以无草稿状态进入工作台：$e');
      draft = null;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => buildSceneWorkspace(selection, draft: draft),
      ),
    );
  }

  /// 查找与本次选择完全匹配的最近草稿（listDrafts 已按更新时间倒序）。
  SceneDraft? _resumableDraft(
    List<SceneDraft> drafts,
    SceneSelection selection,
  ) {
    for (final draft in drafts) {
      final saved = draft.selection;
      if (saved.sceneId == selection.sceneId &&
          saved.elementId == selection.elementId &&
          saved.typeId == selection.typeId) {
        return draft;
      }
    }
    return null;
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 900;
    final isCompact = MediaQuery.sizeOf(context).width < 700;

    return ScenePageScaffold(
      title: _step == 0 ? null : _scene?.name,
      onBack: _step == 0 ? null : _handleBack,
      accent: _step == 0 ? null : _accent,
      backgrounds: _step == 0 || _scene == null
          ? null
          : [
              SceneBackdrop(
                symbol: _scene!.symbol,
                accent: _scene!.accent,
                opacity: 0.28,
                seed: 7,
              ),
            ],
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMobile) ...[
            const ResourceDownloadBanner(compact: true),
            const SizedBox(width: 8),
          ],
          Tooltip(
            message: '运行资源',
            child: GlassCard(
              onTap: () => showResourceManager(context),
              radius: 12,
              padding: EdgeInsets.zero,
              glow: false,
              semanticLabel: '运行资源',
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.download_for_offline_outlined,
                  size: 18,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GlassCard(
            onTap: () => Navigator.of(context).maybePop(),
            radius: 12,
            padding: EdgeInsets.zero,
            glow: false,
            semanticLabel: '关闭场景向导',
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: _step == 0
              ? _buildHallBody(isMobile)
              : _buildWizardBody(isCompact, palette),
        ),
      ),
    );
  }

  /// 第 0 步：Bento 场景大厅。
  Widget _buildHallBody(bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HallHeader(mobile: isMobile),
        SizedBox(height: isMobile ? 16 : 24),
        Expanded(
          child: SceneBentoGrid(
            coding: _animated(
              0,
              _buildCard(SceneRegistry.byId('vibe_coding')!, 0),
              slide: !isMobile,
            ),
            video: _animated(
              1,
              _buildCard(SceneRegistry.byId('vibe_video')!, 1),
              slide: !isMobile,
            ),
            auto: _animated(
              2,
              _buildCard(SceneRegistry.byId('auto')!, 2),
              slide: !isMobile,
            ),
            text: _animated(
              3,
              _buildCard(SceneRegistry.byId('text')!, 3),
              slide: !isMobile,
            ),
            chat: _animated(
              4,
              _buildCard(SceneRegistry.byId('chat')!, 4),
              slide: !isMobile,
            ),
          ),
        ),
      ],
    );
  }

  /// 第 1/2 步：细分元素与项目类型。
  Widget _buildWizardBody(bool compact, ScenePalette palette) {
    final scene = _scene;
    if (scene == null) {
      return Center(
        child: Text(
          '请先选择场景',
          style: SceneTokens.sceneBody(14, color: palette.textSecondary),
        ),
      );
    }

    final cards = <Widget>[];
    if (_step == 1) {
      cards.addAll(
        scene.elements.map(
          (element) => SceneElementCard(
            scene: scene,
            element: element,
            selected: _elementId == element.id,
            onTap: () => _selectElement(element),
          ),
        ),
      );
    } else {
      final elementId = _elementId;
      if (elementId != null) {
        cards.addAll(
          scene.typesForElement(elementId).map(
                (type) => SceneTypeCard(
                  scene: scene,
                  type: type,
                  selected: _typeId == type.id,
                  onTap: () => _selectType(type),
                ),
              ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SceneStepIndicator(
          currentStep: _step,
          labels: const ['场景', '细分元素', '项目类型'],
          accent: _accent,
          onStepTap: (index) {
            // 点「场景」回到大厅；其余仅在回退时可用。
            if (index == 0) {
              setState(() => _step = 0);
            } else if (index < _step) {
              setState(() => _step = index);
            }
          },
        ),
        const SizedBox(height: 14),
        Text(
          _stepTitle,
          style: SceneTokens.sceneTitle(26, color: palette.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          _stepSubtitle,
          style: SceneTokens.sceneBody(
            compact ? 12.5 : 13.5,
            color: palette.textSecondary,
          ),
        ),
        if (_step == 2) ...[
          const SizedBox(height: 10),
          ResourceDownloadBanner(sceneId: _sceneId),
        ],
        const SizedBox(height: 18),
        Expanded(
          child: AnimatedSwitcher(
            duration: SceneTokens.durationPage,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.02),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey<int>(_step),
              child: SceneOptionGrid(cards: cards),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SceneWizardBottomBar(
          compact: compact,
          accent: _accent,
          canContinue: _canContinue,
          submitting: _submitting,
          isLast: _step == 2,
          onBack: _handleBack,
          onNext: _goNext,
        ),
      ],
    );
  }

  Widget _buildCard(SceneDefinition scene, int index) {
    final palette = ScenePalette.of(context);
    final isPrimary = scene.isPrimary;
    final padding = isPrimary ? 32.0 : 28.0;
    final number = (index + 1).toString().padLeft(2, '0');
    final tag = _slotTags[scene.id] ?? '场景';
    final showLastUsed = _lastSceneId == scene.id;

    return GlassCard(
      onTap: () => _selectScene(scene),
      accent: scene.accent,
      radius: SceneTokens.radiusLarge,
      padding: EdgeInsets.zero,
      semanticLabel: '${scene.name}，${scene.tagline}',
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 场景专属动态符号铺满整卡
          Positioned.fill(
            child: SceneBackdrop(
              symbol: scene.symbol,
              accent: scene.accent,
              seed: index + 1,
            ),
          ),
          // 底部压暗，保证文字对比度
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    (palette.isDark ? Colors.black : Colors.white).withValues(
                      alpha: palette.isDark ? 0.30 : 0.34,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$number · $tag',
                      style: SceneTokens.sceneCaption(
                        12,
                        color: scene.accent.withValues(alpha: 0.85),
                        weight: FontWeight.w600,
                      ).copyWith(letterSpacing: 1.2),
                    ),
                    const Spacer(),
                    if (showLastUsed) _LastUsedBadge(accent: scene.accent),
                  ],
                ),
                const Spacer(),
                Padding(
                  padding: EdgeInsets.only(right: isPrimary ? 60 : 52),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTitle(scene, isPrimary, palette),
                      const SizedBox(height: 8),
                      Text(
                        scene.tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: SceneTokens.sceneBody(
                          isPrimary ? 18 : 16,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 右下角圆形箭头指示
          Positioned(
            right: padding,
            bottom: padding,
            child: Container(
              width: isPrimary ? 48 : 42,
              height: isPrimary ? 48 : 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scene.accent.withValues(alpha: 0.14),
                border: Border.all(
                  color: scene.accent.withValues(alpha: 0.55),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: scene.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(
    SceneDefinition scene,
    bool isPrimary,
    ScenePalette palette,
  ) {
    // 移动端单列时收敛字号，避免主卡标题被截断。
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final text = Text(
      scene.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: SceneTokens.sceneTitle(
        isPrimary ? (narrow ? 34 : 56) : (narrow ? 26 : 36),
        color: palette.textPrimary,
      ),
    );
    if (!isPrimary) return text;
    // 主卡标题使用主文字 → 强调色的渐变高亮
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          palette.textPrimary,
          scene.accent.withValues(alpha: 0.92),
        ],
      ).createShader(rect),
      child: text,
    );
  }
}

/// 大厅顶部品牌区。
class _HallHeader extends StatelessWidget {
  const _HallHeader({required this.mobile});

  /// 移动端布局标记：标题字号更小。
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'SLIPE · SCENES',
          style: SceneTokens.sceneCaption(
            12,
            color: palette.textTertiary,
            weight: FontWeight.w600,
          ).copyWith(letterSpacing: 3),
        ),
        const SizedBox(height: 10),
        Text(
          '选择你的场景',
          style: SceneTokens.sceneTitle(
            mobile ? 30 : 34,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '选一个场景，剩下的交给 AI。',
          style: SceneTokens.sceneBody(15, color: palette.textSecondary),
        ),
      ],
    );
  }
}

/// 「上次使用」徽标。
class _LastUsedBadge extends StatelessWidget {
  const _LastUsedBadge({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        '上次使用',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: accent,
          height: 1.2,
        ),
      ),
    );
  }
}
