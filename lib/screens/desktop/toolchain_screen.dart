import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/project_provider.dart';
import '../../providers/toolchain_provider.dart';
import '../../services/toolchain/toolchain_models.dart';

/// 工具链管理页：Flutter / Dart / Node.js / JDK 的安装、切换与校验。
class ToolchainScreen extends StatefulWidget {
  const ToolchainScreen({super.key});

  @override
  State<ToolchainScreen> createState() => _ToolchainScreenState();
}

class _ToolchainScreenState extends State<ToolchainScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: ToolchainKind.values.length,
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ToolchainProvider>();
      provider.initialize();
      for (final kind in ToolchainKind.values) {
        if (provider.releasesOf(kind).isEmpty &&
            !provider.isLoadingReleases(kind)) {
          provider.refreshReleases(kind);
        }
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<ToolchainProvider>();
    final projectPath = context.watch<ProjectProvider>().projectPath;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('desktop.toolchain.title')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(
                  t('desktop.toolchain.mirror'),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: t('desktop.toolchain.mirrorCn'),
                  child: Switch(
                    value: provider.useMirror,
                    onChanged: provider.toggleMirror,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${t('desktop.toolchain.diskUsage')}: '
                '${formatBytes(provider.diskUsage)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            for (final kind in ToolchainKind.values) Tab(text: kind.label),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final kind in ToolchainKind.values)
            _KindPanel(kind: kind, projectPath: projectPath),
        ],
      ),
    );
  }
}

class _KindPanel extends StatelessWidget {
  final ToolchainKind kind;
  final String? projectPath;

  const _KindPanel({required this.kind, required this.projectPath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<ToolchainProvider>();
    final installed = provider.installedOf(kind);
    final releases = provider.releasesOf(kind);
    final progress = provider.progress;
    final activeProgress =
        progress != null && progress.kind == kind ? progress : null;
    final pinned = provider.pinnedVersion(kind, projectPath);
    final defaultVersion = provider.defaultVersion(kind);
    final loading = provider.isLoadingReleases(kind);
    final error = provider.releaseError(kind);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (kind == ToolchainKind.java || kind == ToolchainKind.flutter)
          _androidBanner(context, provider),
        Row(
          children: [
            Text(
              t('desktop.toolchain.installed'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: 8),
            Text(
              '${installed.length}',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: loading
                  ? null
                  : () => provider.refreshReleases(kind, forceRefresh: true),
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 16),
              label: Text(t('desktop.toolchain.refresh')),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (installed.isEmpty)
          _hint(context, '${kind.label} 尚未安装，可在下方选择版本安装。'),
        for (final toolchain in installed)
          _installedTile(
            context,
            provider,
            toolchain,
            isDefault: toolchain.version == defaultVersion,
            isPinned: toolchain.version == pinned,
          ),
        if (activeProgress != null) ...[
          const SizedBox(height: 8),
          _progressCard(context, provider, activeProgress),
        ],
        const SizedBox(height: 16),
        Text(
          t('desktop.toolchain.available'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        if (error == 'noVersions' || (error == null && releases.isEmpty && !loading))
          _hint(context, t('desktop.toolchain.noVersions'))
        else if (error != null)
          _hint(context, error),
        for (final release in releases)
          _releaseTile(context, provider, release, installed),
      ],
    );
  }

  Widget _androidBanner(BuildContext context, ToolchainProvider provider) {
    final sdk = provider.androidSdk;
    final theme = Theme.of(context);
    if (sdk != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Android SDK: $sdk',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('desktop.toolchain.androidMissing'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _installedTile(
    BuildContext context,
    ToolchainProvider provider,
    InstalledToolchain toolchain, {
    required bool isDefault,
    required bool isPinned,
  }) {
    final theme = Theme.of(context);
    final verifyResult = provider.verifyResult(toolchain);
    final verifying = provider.isVerifying(toolchain);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  toolchain.version,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                if (isDefault)
                  _tag(context, t('desktop.toolchain.default'), primary: true),
                if (isPinned) ...[
                  const SizedBox(width: 6),
                  _tag(
                    context,
                    t('desktop.toolchain.projectPinned',
                        {'version': toolchain.version}),
                  ),
                ],
                const Spacer(),
                if (!isDefault)
                  TextButton(
                    onPressed: () => provider.setDefault(kind, toolchain.version),
                    child: Text(t('desktop.toolchain.setDefault')),
                  ),
                TextButton(
                  onPressed: verifying ? null : () => provider.verify(toolchain),
                  child: Text(
                    verifying ? t('desktop.toolchain.verifying') : t('desktop.toolchain.verify'),
                  ),
                ),
                if (projectPath != null)
                  TextButton(
                    onPressed: () => provider.pinProject(
                      kind,
                      projectPath,
                      isPinned ? null : toolchain.version,
                    ),
                    child: Text(
                      isPinned
                          ? t('desktop.toolchain.clearPin')
                          : t('desktop.toolchain.pinProject'),
                    ),
                  ),
                IconButton(
                  tooltip: t('desktop.toolchain.uninstall'),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _confirmUninstall(
                    context,
                    provider,
                    toolchain,
                    isDefault: isDefault,
                  ),
                ),
              ],
            ),
            Text(
              toolchain.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
            if (verifyResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  verifyResult == 'ok'
                      ? t('desktop.toolchain.verifyOk')
                      : verifyResult,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: verifyResult == 'ok'
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _releaseTile(
    BuildContext context,
    ToolchainProvider provider,
    ToolchainRelease release,
    List<InstalledToolchain> installed,
  ) {
    final theme = Theme.of(context);
    final isInstalled =
        installed.any((item) => item.version == release.version);
    final busy = provider.installing;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Row(
        children: [
          Text(release.version),
          if (release.lts) ...[
            const SizedBox(width: 6),
            _tag(context, 'LTS'),
          ],
          if (release.sizeBytes != null) ...[
            const SizedBox(width: 8),
            Text(
              formatBytes(release.sizeBytes!),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      subtitle: Text(
        release.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isInstalled
          ? Text(
              t('desktop.toolchain.ready'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            )
          : FilledButton.tonal(
              onPressed: busy ? null : () => provider.install(release),
              child: Text(t('desktop.toolchain.install')),
            ),
    );
  }

  Widget _progressCard(
    BuildContext context,
    ToolchainProvider provider,
    ToolchainProgress progress,
  ) {
    final theme = Theme.of(context);
    final label = switch (progress.phase) {
      ToolchainPhase.queued => t('desktop.toolchain.downloading'),
      ToolchainPhase.downloading => t('desktop.toolchain.downloading'),
      ToolchainPhase.verifying => t('desktop.toolchain.verifying'),
      ToolchainPhase.extracting => t('desktop.toolchain.extracting'),
      ToolchainPhase.installing => t('desktop.toolchain.installing'),
      ToolchainPhase.done => t('desktop.toolchain.ready'),
      ToolchainPhase.failed => t('desktop.toolchain.failed'),
      ToolchainPhase.cancelled => t('desktop.toolchain.cancel'),
    };
    final running = progress.phase.isRunning;
    final failed = progress.phase == ToolchainPhase.failed;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${progress.kind.label} ${progress.version} · $label'
                    '${progress.total > 0 && progress.phase == ToolchainPhase.downloading ? '  ${formatBytes(progress.received)} / ${formatBytes(progress.total)}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (running)
                  TextButton(
                    onPressed: provider.cancelInstall,
                    child: Text(t('desktop.toolchain.cancel')),
                  ),
                if (failed)
                  TextButton(
                    onPressed: () => provider.refreshReleases(
                      progress.kind,
                      forceRefresh: true,
                    ),
                    child: Text(t('desktop.toolchain.retryMirror')),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: failed || !running ? null : progress.fraction,
              minHeight: 3,
            ),
            if (progress.message.isNotEmpty &&
                progress.phase != ToolchainPhase.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  progress.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tag(BuildContext context, String text, {bool primary = false}) {
    final theme = Theme.of(context);
    final color = primary
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  Future<void> _confirmUninstall(
    BuildContext context,
    ToolchainProvider provider,
    InstalledToolchain toolchain, {
    required bool isDefault,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${t('desktop.toolchain.uninstall')} ${toolchain.kind.label} ${toolchain.version}'),
        content: Text(
          isDefault
              ? '该版本当前是默认版本，卸载后将回退到其他已安装版本或系统安装。'
              : '将删除 ${toolchain.path}，此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('desktop.toolchain.uninstall')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await provider.uninstall(toolchain);
    }
  }
}
