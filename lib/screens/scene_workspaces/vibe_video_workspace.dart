import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/scene.dart';
import '../../providers/project_provider.dart';
import '../../services/desktop_platform.dart';
import '../../services/scene_registry.dart';
import '../../services/scene_session_service.dart';
import '../../services/video_editor_service.dart';
import '../../services/video_render_service.dart';
import '../../widgets/scene/scene_backdrop.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import '../ai_chat_screen.dart';
import 'workspace_shell.dart';

/// 移动端断点：手机端暂不支持完整剪辑与 HyperFrames 渲染。
const double _kVideoMobileBreakpoint = 900;

/// VibeVideo 真实剪辑工作台（桌面端）。
///
/// 结构：左侧素材库 · 中间预览 + 时间线 · 右侧 AI 对话。
/// 数据由 [VideoEditorService] 统一承载，AI 通过 MCP 工具操作同一份状态，
/// 用户亦可直接在时间线上做后处理；导出交给 [VideoRenderService]。
class VibeVideoWorkspace extends StatefulWidget {
  const VibeVideoWorkspace({super.key, required this.selection, this.draft});

  final SceneSelection selection;
  final SceneDraft? draft;

  @override
  State<VibeVideoWorkspace> createState() => _VibeVideoWorkspaceState();
}

class _VibeVideoWorkspaceState extends State<VibeVideoWorkspace> {
  SceneDefinition? _scene;
  Timer? _playTimer;
  bool _playing = false;
  bool _exporting = false;

  final VideoEditorService _editor = VideoEditorService.instance;

  Color get _accent => _scene?.accent ?? const Color(0xFFA78BFA);

  Color _accentText(ScenePalette palette) => palette.isDark
      ? _accent
      : (Color.lerp(_accent, Colors.black, 0.3) ?? _accent);

  @override
  void initState() {
    super.initState();
    _scene = SceneRegistry.byId(widget.selection.sceneId);
    final projectPath = context.read<ProjectProvider>().projectPath;
    final name = widget.selection.typeId == null
        ? '未命名视频'
        : '${_scene?.typeById(widget.selection.typeId!)?.name ?? '视频'}项目';
    unawaited(_editor.openForProject(projectPath, name: name));
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  // ---------------- 播放 ----------------

  void _togglePlay() {
    final project = _editor.project;
    if (project == null || project.clips.isEmpty) return;
    setState(() => _playing = !_playing);
    if (_playing) {
      _playTimer?.cancel();
      _playTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final total = project.totalDuration;
        final next = _editor.playhead + 0.1;
        if (next >= total) {
          _editor.setPlayhead(0);
          _stopPlay();
        } else {
          _editor.setPlayhead(next);
        }
      });
    } else {
      _playTimer?.cancel();
    }
  }

  void _stopPlay() {
    _playTimer?.cancel();
    if (mounted) setState(() => _playing = false);
  }

  void _toast(String message) {
    if (!mounted) return;
    final palette = ScenePalette.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: SceneTokens.sceneBody(13, color: palette.textPrimary),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: palette.codeBackground,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ---------------- 素材 ----------------

  Future<void> _pickAssets() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        dialogTitle: '导入素材',
      );
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final file in result.files) {
        final path = file.path;
        if (path == null || path.isEmpty) continue;
        if (_editor.addAsset(path, name: file.name) != null) added++;
      }
      if (added == 0) {
        _toast('未新增素材');
      } else {
        _toast('已导入 $added 个素材');
      }
    } catch (e) {
      _toast('导入素材失败：$e');
    }
  }

  void _addAssetToTimeline(VideoAsset asset) {
    final clip = _editor.addClip(assetId: asset.id);
    if (clip == null) return;
    _toast('已加入时间线：${asset.name}');
    _stopPlay();
  }

  void _addTextClip() {
    final clip = _editor.addTextClip(
      text: '在这里输入字幕内容',
      title: '字幕 ${(_editor.project?.clips.length ?? 0) + 1}',
    );
    _editor.selectClip(clip.id);
    _stopPlay();
  }

  // ---------------- 导出 ----------------

  Future<void> _export() async {
    final project = _editor.project;
    if (project == null) return;
    if (project.clips.isEmpty) {
      _toast('时间线为空，请先添加片段');
      return;
    }
    setState(() => _exporting = true);
    final result = await VideoRenderService.instance.render(
      project,
      rootPath: _editor.rootPath,
    );
    if (!mounted) return;
    setState(() => _exporting = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.ok ? '导出完成' : '导出失败'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                result.message,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              if (result.log.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  height: 160,
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      result.log,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (result.outputDir != null)
            TextButton(
              onPressed: () =>
                  DesktopPlatform.revealInFileManager(result.outputDir!),
              child: const Text('打开目录'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final isMobile =
        MediaQuery.sizeOf(context).width < _kVideoMobileBreakpoint;

    return ListenableBuilder(
      listenable: _editor,
      builder: (context, _) {
        final project = _editor.project;
        final subtitle = project == null
            ? '正在载入项目…'
            : '${project.clips.length} 个片段 · '
                '${project.width}×${project.height} · '
                '${project.totalDuration.toStringAsFixed(1)}s';

        return WorkspaceShell(
          title: 'VibeVideo',
          subtitle: subtitle,
          accent: _accent,
          symbol: SceneSymbolKind.video,
          statusLabel: project == null ? '加载中' : '本地已保存',
          actions: [
            if (!isMobile)
              _HeaderAction(
                label: _exporting ? '导出中…' : '导出视频',
                icon: Icons.movie_creation_outlined,
                accent: _accent,
                busy: _exporting,
                onTap: _exporting ? null : _export,
              ),
            if (!isMobile)
              _HeaderAction(
                label: 'AI 助手',
                icon: Icons.auto_awesome,
                accent: _accent,
                onTap: _showAiDialog,
              ),
            _HeaderAction(
              label: '设置',
              icon: Icons.tune,
              accent: _accent,
              onTap: () => _showProjectSettings(),
            ),
          ],
          leftPanel: isMobile ? null : _buildAssetPanel(palette),
          rightPanel: isMobile ? null : const _VideoAiPanel(),
          body: isMobile
              ? _buildMobileBody(palette)
              : _buildDesktopBody(palette),
        );
      },
    );
  }

  Widget _buildDesktopBody(ScenePalette palette) {
    final project = _editor.project;
    if (project == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildPreview(palette, project)),
        const SizedBox(height: 12),
        _buildTransport(palette, project),
        const SizedBox(height: 12),
        SizedBox(
          height: 172,
          child: _buildTimeline(palette, project),
        ),
        const SizedBox(height: 12),
        _buildInspector(palette),
      ],
    );
  }

  Widget _buildMobileBody(ScenePalette palette) {
    final project = _editor.project;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
          child: Row(
            children: [
              Icon(Icons.movie_filter_outlined,
                  size: 18, color: _accentText(palette)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'VibeVideo 完整剪辑与 HyperFrames 渲染仅支持桌面端，'
                  '当前可浏览素材与时间线。',
                  style:
                      SceneTokens.sceneBody(12.5, color: palette.textSecondary),
                ),
              ),
            ],
          ),
        ),
        if (project == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          )
        else ...[
          _buildPreview(palette, project),
          const SizedBox(height: 12),
          SizedBox(height: 172, child: _buildTimeline(palette, project)),
          const SizedBox(height: 12),
          _buildAssetPanel(palette),
        ],
      ],
    );
  }

  // ---------------- 预览 ----------------

  Widget _buildPreview(ScenePalette palette, VideoProjectData project) {
    final at = _editor.clipAt(_editor.playhead);
    final clip = _editor.selectedClip ?? at?.clip;
    final asset = project.assetOf(clip?.assetId);

    Widget content;
    if (clip == null) {
      content = Center(
        child: Text(
          '时间线为空，请从左侧素材库添加片段',
          style: SceneTokens.sceneBody(13, color: palette.textSecondary),
        ),
      );
    } else if (asset != null && asset.kind == VideoAssetKind.image) {
      final file = File(asset.path);
      content = file.existsSync()
          ? Image.file(file, fit: BoxFit.contain)
          : _missingAsset(palette, asset.name);
    } else if (asset != null && asset.kind == VideoAssetKind.video) {
      content = Stack(
        children: [
          Positioned.fill(
            child: SceneBackdrop(
              symbol: SceneSymbolKind.video,
              accent: _accent,
              opacity: 0.85,
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_outlined, size: 34, color: _accent),
                const SizedBox(height: 8),
                Text(
                  asset.name,
                  style: SceneTokens.sceneBody(
                    12.5,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () =>
                      DesktopPlatform.revealInFileManager(asset.path),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('在文件管理器中打开'),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      content = Container(
        padding: const EdgeInsets.all(28),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              clip.title,
              textAlign: TextAlign.center,
              style: SceneTokens.sceneTitle(26, color: palette.textPrimary),
            ),
            if (clip.text.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                clip.text,
                textAlign: TextAlign.center,
                style: SceneTokens.sceneBody(
                  14,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.isDark ? palette.codeBackground : palette.bgBottom,
        borderRadius: BorderRadius.circular(SceneTokens.radiusSmall),
        border: Border.all(color: _accent.withValues(alpha: 0.28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            left: 12,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.glassFillStrong,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                clip == null
                    ? '${project.width}×${project.height}'
                    : '${clip.title} · ${clip.duration.toStringAsFixed(1)}s',
                style: SceneTokens.sceneCaption(
                  10.5,
                  color: palette.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _missingAsset(ScenePalette palette, String name) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 30, color: palette.textTertiary),
          const SizedBox(height: 8),
          Text(
            '素材文件不存在：$name',
            style: SceneTokens.sceneBody(12, color: palette.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildTransport(ScenePalette palette, VideoProjectData project) {
    final total = project.totalDuration;
    return Row(
      children: [
        _TransportButton(
          icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          accent: _accent,
          onTap: _togglePlay,
        ),
        const SizedBox(width: 10),
        Text(
          '${_fmt(_editor.playhead)} / ${_fmt(total)}',
          style: SceneTokens.sceneCaption(12, color: palette.textSecondary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: _accent,
              thumbColor: _accent,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: total <= 0 ? 0 : _editor.playhead.clamp(0, total).toDouble(),
              max: total <= 0 ? 1 : total,
              onChanged: total <= 0
                  ? null
                  : (value) {
                      _stopPlay();
                      _editor.setPlayhead(value);
                    },
            ),
          ),
        ),
      ],
    );
  }

  String _fmt(double seconds) {
    final s = seconds.clamp(0, 360000).toDouble();
    final m = s ~/ 60;
    final rest = s - m * 60;
    return '${m.toString().padLeft(2, '0')}:'
        '${rest.toStringAsFixed(1).padLeft(4, '0')}';
  }

  // ---------------- 时间线 ----------------

  Widget _buildTimeline(ScenePalette palette, VideoProjectData project) {
    return WorkspaceSection(
      title: '时间线 · ${project.clips.length} 个片段',
      accent: _accent,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MiniAction(
            icon: Icons.text_fields,
            label: '文本片段',
            accent: _accent,
            onTap: _addTextClip,
          ),
          const SizedBox(width: 6),
          _MiniAction(
            icon: Icons.add_photo_alternate_outlined,
            label: '添加素材',
            accent: _accent,
            onTap: _pickAssets,
          ),
        ],
      ),
      child: SizedBox(
        height: 112,
        child: project.clips.isEmpty
            ? Center(
                child: Text(
                  '还没有片段。从左侧素材库点击「加入时间线」。',
                  style:
                      SceneTokens.sceneCaption(12, color: palette.textTertiary),
                ),
              )
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 2),
                itemCount: project.clips.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final clip = project.clips[index];
                  return _ClipCard(
                    index: index,
                    clip: clip,
                    asset: project.assetOf(clip.assetId),
                    selected: _editor.selectedClipId == clip.id,
                    accent: _accent,
                    onTap: () => _editor.selectClip(clip.id),
                    onLeft: index == 0
                        ? null
                        : () => _editor.moveClip(index, index - 1),
                    onRight: index == project.clips.length - 1
                        ? null
                        : () => _editor.moveClip(index, index + 1),
                    onDelete: () => _editor.removeClip(clip.id),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildInspector(ScenePalette palette) {
    final clip = _editor.selectedClip;
    final project = _editor.project;
    if (clip == null || project == null) {
      return Container(
        height: 64,
        alignment: Alignment.center,
        decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
        child: Text(
          '选中时间线上的片段即可调整时长、转场与字幕。',
          style: SceneTokens.sceneCaption(12, color: palette.textTertiary),
        ),
      );
    }
    final asset = project.assetOf(clip.assetId);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(
              _iconForAsset(asset),
              size: 16,
              color: _accentText(palette),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 160,
              child: Text(
                clip.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SceneTokens.sceneBody(
                  13,
                  color: palette.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _NumberField(
              label: '时长(s)',
              value: clip.duration,
              accent: _accent,
              onChanged: (v) => _editor.updateClip(clip.id, duration: v),
            ),
            if (asset != null &&
                (asset.kind == VideoAssetKind.video ||
                    asset.kind == VideoAssetKind.audio)) ...[
              const SizedBox(width: 12),
              _NumberField(
                label: '起点(s)',
                value: clip.inPoint,
                accent: _accent,
                onChanged: (v) => _editor.updateClip(clip.id, inPoint: v),
              ),
            ],
            const SizedBox(width: 12),
            _TransitionPicker(
              value: clip.transition,
              accent: _accent,
              onChanged: (v) => _editor.updateClip(clip.id, transition: v),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: _InlineTextField(
                initial: clip.text,
                hint: '字幕 / 文案',
                accent: _accent,
                onChanged: (v) => _editor.updateClip(clip.id, text: v),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 素材面板 ----------------

  Widget _buildAssetPanel(ScenePalette palette) {
    final project = _editor.project;
    final assets = project?.assets ?? const <VideoAsset>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text(
                '素材库',
                style: SceneTokens.sceneTitle(16, color: palette.textPrimary),
              ),
              const Spacer(),
              Text(
                '${assets.length} 项',
                style: SceneTokens.sceneCaption(11, color: palette.textTertiary),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 38,
          child: OutlinedButton.icon(
            onPressed: _pickAssets,
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.textPrimary,
              side: BorderSide(color: _accent.withValues(alpha: 0.4)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text(
              '导入素材',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: palette.glassDecoration(
              radius: SceneTokens.radiusSmall,
            ),
            child: assets.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library_outlined,
                          size: 26,
                          color: palette.textTertiary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '导入图片、视频或音频\n点击素材即可加入时间线',
                          textAlign: TextAlign.center,
                          style: SceneTokens.sceneCaption(
                            12,
                            color: palette.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: assets.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final asset = assets[index];
                      return _AssetTile(
                        asset: asset,
                        accent: _accent,
                        onAdd: () => _addAssetToTimeline(asset),
                        onRemove: () => _editor.removeAsset(asset.id),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// 窄窗口下右侧 AI 栏会被隐藏，这里用弹窗提供完整对话入口。
  Future<void> _showAiDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final width = size.width * 0.9 < 560 ? size.width * 0.9 : 560.0;
        final height = size.height * 0.86 < 760 ? size.height * 0.86 : 760.0;
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: const AiChatScreen(),
          ),
        );
      },
    );
  }

  Future<void> _showProjectSettings() async {
    final project = _editor.project;
    if (project == null) return;
    final nameCtrl = TextEditingController(text: project.name);
    int width = project.width;
    int height = project.height;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('视频设置'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '项目名称',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _editor.renameProject,
                ),
                const SizedBox(height: 14),
                const Text('分辨率', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [
                      (1920, 1080, '16:9'),
                      (1080, 1920, '9:16'),
                      (1080, 1080, '1:1'),
                      (2560, 1440, '2K'),
                    ])
                      ChoiceChip(
                        label: Text('${preset.$3} ${preset.$1}×${preset.$2}'),
                        selected: width == preset.$1 && height == preset.$2,
                        onSelected: (_) {
                          setLocal(() {
                            width = preset.$1;
                            height = preset.$2;
                          });
                          _editor.setResolution(width: width, height: height);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Text('帧率', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 12),
                    for (final fps in const [24.0, 25.0, 30.0, 60.0]) ...[
                      ChoiceChip(
                        label: Text('${fps.toStringAsFixed(0)}fps'),
                        selected: project.fps == fps,
                        onSelected: (_) => _editor.setFps(fps),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
  }
}

// ---------------------------------------------------------------------------
// 右侧 AI 面板
// ---------------------------------------------------------------------------

class _VideoAiPanel extends StatelessWidget {
  const _VideoAiPanel();

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
      clipBehavior: Clip.antiAlias,
      child: const AiChatScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// 小组件
// ---------------------------------------------------------------------------

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.label,
    required this.icon,
    required this.accent,
    this.onTap,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return SizedBox(
      height: 34,
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: accent.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: busy
            ? SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: accent,
                ),
              )
            : Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: SceneTokens.sceneCaption(
                11,
                color: palette.textSecondary,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent.withValues(alpha: 0.16),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(icon, size: 22, color: accent),
        ),
      ),
    );
  }
}

IconData _iconForAsset(VideoAsset? asset) => switch (asset?.kind) {
      VideoAssetKind.image => Icons.image_outlined,
      VideoAssetKind.video => Icons.videocam_outlined,
      VideoAssetKind.audio => Icons.audiotrack_outlined,
      _ => Icons.description_outlined,
    };

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.accent,
    required this.onAdd,
    required this.onRemove,
  });

  final VideoAsset asset;
  final Color accent;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: palette.glassFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.glassBorder),
          ),
          child: Row(
            children: [
              Icon(
                _iconForAsset(asset),
                size: 16,
                color: accent.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      asset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SceneTokens.sceneBody(
                        12,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      videoAssetKindLabel(asset.kind),
                      style: SceneTokens.sceneCaption(
                        10.5,
                        color: palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: onAdd,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.playlist_add, size: 16),
                ),
              ),
              InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: palette.textTertiary,
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

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    required this.index,
    required this.clip,
    required this.asset,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.onLeft,
    this.onRight,
    required this.onDelete,
  });

  final int index;
  final VideoClip clip;
  final VideoAsset? asset;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: SceneTokens.durationFast,
          width: 168,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: palette.isDark ? 0.16 : 0.12)
                : palette.glassFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.6) : palette.glassBorder,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: SceneTokens.sceneCaption(
                        10,
                        color: accent,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      clip.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SceneTokens.sceneBody(
                        12.5,
                        color: palette.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(_iconForAsset(asset), size: 12, color: palette.textTertiary),
                  const SizedBox(width: 4),
                  Text(
                    '${clip.duration.toStringAsFixed(1)}s',
                    style: SceneTokens.sceneCaption(
                      10.5,
                      color: palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (clip.transition != 'none')
                    Text(
                      clip.transition,
                      style: SceneTokens.sceneCaption(
                        10,
                        color: accent,
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  _clipIcon(Icons.chevron_left, onLeft, palette),
                  _clipIcon(Icons.chevron_right, onRight, palette),
                  const Spacer(),
                  _clipIcon(Icons.delete_outline_rounded, onDelete, palette),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _clipIcon(IconData icon, VoidCallback? onTap, ScenePalette palette) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          icon,
          size: 16,
          color: onTap == null ? palette.textTertiary : palette.textSecondary,
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  final String label;
  final double value;
  final Color accent;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return SizedBox(
      width: 108,
      height: 34,
      child: TextFormField(
        key: ValueKey('$label-$value'),
        initialValue: value.toStringAsFixed(1),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        cursorColor: accent,
        style: SceneTokens.sceneBody(12, color: palette.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          labelStyle: TextStyle(fontSize: 10, color: palette.textTertiary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: palette.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: accent),
          ),
        ),
        onFieldSubmitted: (text) {
          final parsed = double.tryParse(text.trim());
          if (parsed != null && parsed > 0) onChanged(parsed);
        },
      ),
    );
  }
}

class _InlineTextField extends StatelessWidget {
  const _InlineTextField({
    required this.initial,
    required this.hint,
    required this.accent,
    required this.onChanged,
  });

  final String initial;
  final String hint;
  final Color accent;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return SizedBox(
      height: 34,
      child: TextFormField(
        key: ValueKey('inline-$initial'),
        initialValue: initial,
        cursorColor: accent,
        style: SceneTokens.sceneBody(12, color: palette.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 12, color: palette.textTertiary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: palette.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: accent),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _TransitionPicker extends StatelessWidget {
  const _TransitionPicker({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  final String value;
  final Color accent;
  final ValueChanged<String> onChanged;

  static const _options = [
    ('none', '无'),
    ('fade', '淡入'),
    ('slide', '滑动'),
    ('zoom', '缩放'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _options.any((o) => o.$1 == value) ? value : 'none',
        isDense: true,
        dropdownColor: palette.codeBackground,
        icon: Icon(Icons.swap_horiz, size: 15, color: accent),
        style: SceneTokens.sceneBody(12, color: palette.textPrimary),
        items: [
          for (final option in _options)
            DropdownMenuItem(value: option.$1, child: Text(option.$2)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
