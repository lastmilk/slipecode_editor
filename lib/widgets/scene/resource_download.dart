import 'package:flutter/material.dart';

import '../../models/ondemand_resource.dart';
import '../../services/resource_download_service.dart';
import 'scene_palette.dart';
import 'scene_tokens.dart';

/// 首次进入场景大厅时的资源下载提示。
///
/// 文案：需要下载 XXX 的资源，是否下载？
Future<void> showResourceDownloadPrompt(
  BuildContext context, {
  required List<OnDemandResource> resources,
  bool firstLaunch = false,
}) async {
  if (resources.isEmpty) return;
  final names = resources.map((r) => r.name).join('、');
  await showDialog<void>(
    context: context,
    barrierDismissible: !firstLaunch,
    builder: (dialogContext) => _ResourceDownloadDialog(
      resources: resources,
      title: firstLaunch ? '需要下载运行资源' : '运行资源',
      message: firstLaunch
          ? '需要下载 $names 的资源，是否下载？'
          : '以下资源尚未安装，安装后对应场景才能使用完整能力。',
    ),
  );
}

/// 打开资源管理对话框（可查看全部资源并下载/卸载）。
Future<void> showResourceManager(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => const _ResourceDownloadDialog(
      resources: null,
      title: '运行资源',
      message: '这些内核按需下载，只在对应场景使用，不会占用启动时间。',
    ),
  );
}

class _ResourceDownloadDialog extends StatefulWidget {
  const _ResourceDownloadDialog({
    required this.resources,
    required this.title,
    required this.message,
  });

  /// 为 null 时展示全部资源。
  final List<OnDemandResource>? resources;
  final String title;
  final String message;

  @override
  State<_ResourceDownloadDialog> createState() =>
      _ResourceDownloadDialogState();
}

class _ResourceDownloadDialogState extends State<_ResourceDownloadDialog> {
  final ResourceDownloadService _service = ResourceDownloadService.instance;

  @override
  void initState() {
    super.initState();
    _service.ensureLoaded();
  }

  List<OnDemandResource> get _items =>
      widget.resources ?? OnDemandResources.all;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final dialogWidth = width < 700 ? width - 32 : 640.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: dialogWidth,
        constraints: const BoxConstraints(maxHeight: 640),
        decoration: palette.glassDecoration(
          radius: 24,
          glow: true,
          // 对话框需要足够不透明，避免背景内容透出影响阅读。
          color: palette.isDark
              ? const Color(0xF2151519)
              : const Color(0xFAFFFFFF),
        ),
        child: AnimatedBuilder(
          animation: _service,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 14, 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.download_for_offline_outlined,
                        size: 20,
                        color: palette.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: SceneTokens.sceneTitle(
                            18,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.maybePop(context),
                        icon: Icon(Icons.close_rounded, color: palette.textTertiary),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Text(
                    widget.message,
                    style: SceneTokens.sceneBody(
                      13,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _buildResourceTile(context, palette, _items[index]),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: palette.glassFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: palette.glassBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '启用按需下载',
                                style: SceneTokens.sceneBody(
                                  13,
                                  color: palette.textPrimary,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '下载源：${_service.serverUrl}'
                                '${_service.enabled ? '' : '（已关闭）'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: SceneTokens.sceneCaption(
                                  10.5,
                                  color: palette.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _service.enabled,
                          onChanged: _service.setEnabled,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildResourceTile(
    BuildContext context,
    ScenePalette palette,
    OnDemandResource resource,
  ) {
    final state = _service.stateOf(resource.id);
    final installed = state.isInstalled;
    final busy = state.isBusy;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: installed
              ? const Color(0xFF00F07A).withValues(alpha: 0.35)
              : palette.glassBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resource.name,
                      style: SceneTokens.sceneBody(
                        14,
                        color: palette.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      resource.summary,
                      style: SceneTokens.sceneCaption(
                        11.5,
                        color: palette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${resource.purpose} · ${resource.approxSize} · ${resource.license}',
                      style: SceneTokens.sceneCaption(
                        11,
                        color: palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _buildAction(resource, state),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.progress <= 0 ? null : state.progress,
                minHeight: 4,
                backgroundColor: palette.inputFill,
                color: const Color(0xFF00F07A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              state.message ?? '',
              style: SceneTokens.sceneCaption(10.5, color: palette.textTertiary),
            ),
          ],
          if (state.status == ResourceInstallStatus.failed &&
              !busy &&
              (state.message?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 8),
            SelectableText(
              state.message!,
              style: SceneTokens.sceneCaption(
                10.5,
                color: Colors.redAccent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAction(OnDemandResource resource, ResourceState state) {
    if (state.isInstalled) {
      return SizedBox(
        height: 36,
        child: OutlinedButton(
          onPressed: () => _service.remove(resource.id),
          child: const Text('卸载', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    if (state.isBusy) {
      return const SizedBox(
        height: 36,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SizedBox(
      height: 36,
      child: FilledButton(
        onPressed: () => _service.download(resource.id),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF00F07A),
          foregroundColor: const Color(0xFF06120B),
        ),
        child: Text(
          state.status == ResourceInstallStatus.failed ? '重试' : '下载',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// 大厅/工作台中的资源提示条：显示缺失数量并提供下载入口。
class ResourceDownloadBanner extends StatelessWidget {
  const ResourceDownloadBanner({super.key, this.sceneId, this.compact = false});

  /// 仅统计某场景缺失的资源；为空时统计全部。
  final String? sceneId;

  /// 紧凑模式用于顶栏。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final service = ResourceDownloadService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        if (!service.enabled) return const SizedBox.shrink();
        final missing = sceneId == null
            ? service.missing
            : service.missingForScene(sceneId!);
        if (missing.isEmpty) return const SizedBox.shrink();
        final palette = ScenePalette.of(context);
        final label = '${missing.length} 项资源未安装';
        if (compact) {
          return TextButton.icon(
            onPressed: () => showResourceManager(context),
            icon: const Icon(Icons.download_for_offline_outlined, size: 16),
            label: Text(label, style: const TextStyle(fontSize: 12)),
          );
        }
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showResourceDownloadPrompt(context, resources: missing),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: palette.glassFill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.glassBorder),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.download_for_offline_outlined,
                  size: 18,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '需要下载 $label 的内核，是否下载？',
                    style: SceneTokens.sceneCaption(
                      12,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
