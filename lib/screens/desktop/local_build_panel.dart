import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/local_build_provider.dart';
import '../../providers/project_provider.dart';
import '../../services/desktop_platform.dart';
import '../../services/local_build/local_build_models.dart';
import '../../services/toolchain/toolchain_models.dart';
import '../../widgets/desktop/desktop_dialogs.dart';

/// 构建页「本地构建」分页。
class LocalBuildPanel extends StatefulWidget {
  const LocalBuildPanel({super.key});

  @override
  State<LocalBuildPanel> createState() => _LocalBuildPanelState();
}

class _LocalBuildPanelState extends State<LocalBuildPanel> {
  LocalBuildTarget? _target;
  LocalTaskKind _kind = LocalTaskKind.build;
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<LocalBuildProvider>().loadHistory();
    });
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  List<LocalBuildTarget> _targets(String? payloadId) =>
      localTargetsFor(payloadId ?? '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = context.watch<ProjectProvider>();
    final build = context.watch<LocalBuildProvider>();
    final projectPath = project.projectPath;
    final payloadId = project.payload.id;
    final targets = _targets(payloadId);
    final target = _target ?? targets.firstOrNull;
    final task = build.current;
    final error = build.lastError;

    if (projectPath == null) {
      return Center(
        child: Text(
          '请先打开一个项目',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(theme, targets, target, build, projectPath, payloadId),
        if (error != null) ...[
          const SizedBox(height: 10),
          _banner(theme, error, isError: true),
        ],
        if (target != null &&
            build.prerequisiteError(target, projectPath: projectPath) != null)
          _banner(
            theme,
            build.prerequisiteError(target, projectPath: projectPath)!,
            isError: true,
            action: TextButton(
              onPressed: () => showToolchainDialog(context),
              child: const Text('打开工具链'),
            ),
          ),
        const SizedBox(height: 14),
        if (task != null) ...[
          _taskCard(theme, build, task),
          const SizedBox(height: 14),
        ],
        if (task != null && task.artifacts.isNotEmpty) ...[
          _artifactsCard(theme, build, task),
          const SizedBox(height: 14),
        ],
        if (task != null) _logCard(theme, build, task),
        const SizedBox(height: 16),
        if (build.history.isNotEmpty) _historyCard(theme, build),
      ],
    );
  }

  Widget _header(
    ThemeData theme,
    List<LocalBuildTarget> targets,
    LocalBuildTarget? target,
    LocalBuildProvider build,
    String projectPath,
    String payloadId,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                projectPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (build.previewUri != null)
              TextButton.icon(
                onPressed: () =>
                    DesktopPlatform.openInBrowser(build.previewUri.toString()),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(build.previewUri.toString()),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<LocalBuildTarget>(
              value: target,
              hint: const Text('构建目标'),
              items: [
                for (final item in targets)
                  DropdownMenuItem(value: item, child: Text(item.label)),
              ],
              onChanged: (value) => setState(() => _target = value),
            ),
            SegmentedButton<LocalTaskKind>(
              segments: [
                for (final kind in LocalTaskKind.values)
                  ButtonSegment(value: kind, label: Text(kind.label)),
              ],
              selected: {_kind},
              onSelectionChanged: (selection) =>
                  setState(() => _kind = selection.first),
            ),
            if (build.isRunning)
              FilledButton.tonalIcon(
                onPressed: build.cancel,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('停止'),
              )
            else
              FilledButton.icon(
                onPressed: target == null
                    ? null
                    : () => _start(build, projectPath, payloadId, target),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(
                  _kind == LocalTaskKind.run ? '运行' : '开始${_kind.label}',
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _start(
    LocalBuildProvider build,
    String projectPath,
    String payloadId,
    LocalBuildTarget target,
  ) async {
    await build.start(
      projectPath: projectPath,
      payloadId: payloadId,
      target: target,
      kind: _kind,
    );
  }

  Widget _banner(
    ThemeData theme,
    String message, {
    bool isError = false,
    Widget? action,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:
            (isError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.surfaceContainerHighest)
                .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 16,
            color: isError ? theme.colorScheme.error : null,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _taskCard(
    ThemeData theme,
    LocalBuildProvider build,
    LocalBuildTask task,
  ) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (task.status) {
                    LocalTaskStatus.running => Icons.hourglass_top,
                    LocalTaskStatus.success => Icons.check_circle_outline,
                    LocalTaskStatus.failed => Icons.error_outline,
                    LocalTaskStatus.cancelled => Icons.cancel_outlined,
                  },
                  size: 16,
                  color: switch (task.status) {
                    LocalTaskStatus.running => theme.colorScheme.primary,
                    LocalTaskStatus.success => const Color(0xFF2E7D32),
                    LocalTaskStatus.failed => theme.colorScheme.error,
                    LocalTaskStatus.cancelled =>
                      theme.colorScheme.onSurfaceVariant,
                  },
                ),
                const SizedBox(width: 6),
                Text(
                  '${task.kind.label} · ${task.target.label}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (task.finishedAt != null)
                  Text(
                    _formatDuration(
                      task.finishedAt!.difference(task.startedAt),
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if (task.status == LocalTaskStatus.running) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
            ],
            const SizedBox(height: 6),
            for (final step in task.steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      switch (step.status) {
                        LocalStepStatus.pending => Icons.radio_button_unchecked,
                        LocalStepStatus.running => Icons.autorenew,
                        LocalStepStatus.success => Icons.check,
                        LocalStepStatus.failed => Icons.close,
                        LocalStepStatus.skipped => Icons.remove,
                      },
                      size: 13,
                      color: switch (step.status) {
                        LocalStepStatus.running => theme.colorScheme.primary,
                        LocalStepStatus.success => const Color(0xFF2E7D32),
                        LocalStepStatus.failed => theme.colorScheme.error,
                        _ => theme.colorScheme.onSurfaceVariant,
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(step.name, style: theme.textTheme.bodySmall),
                    ),
                    Text(
                      step.displayCommand,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  task.error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (task.status == LocalTaskStatus.failed &&
                _failureHint(task) != null) ...[
              const SizedBox(height: 8),
              _banner(theme, _failureHint(task)!, isError: true),
            ],
          ],
        ),
      ),
    );
  }

  /// 根据构建日志给出可执行的修复建议
  String? _failureHint(LocalBuildTask task) {
    final text = task.logs.join('\n');
    if (text.contains('Unsupported class file major version') ||
        text.contains('Unsupported Java')) {
      return '当前 JDK 版本过高，Flutter / Gradle 需要 JDK 17 或 21。'
          '请在「工具链」中安装兼容的 JDK 并切换后重试。';
    }
    if (text.contains('build.gradle') &&
        (text.contains('could not be found') ||
            text.contains('No such file or directory'))) {
      return '项目缺少平台工程目录（android/）。重新构建会自动补齐，'
          '若仍失败请检查项目是否完整。';
    }
    if (text.contains('SDK location not found') ||
        text.contains('ANDROID_HOME') ||
        text.contains('sdk.dir')) {
      return '未找到 Android SDK。请在「工具链」中确认 Android SDK 路径后重试。';
    }
    if (text.contains('JAVA_HOME')) {
      return '未找到可用的 JDK。请在「工具链」中安装 JDK 17 或 21 后重试。';
    }
    return null;
  }

  Widget _artifactsCard(
    ThemeData theme,
    LocalBuildProvider build,
    LocalBuildTask task,
  ) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('产物', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final artifact in task.artifacts)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  artifact.path.endsWith('/')
                      ? Icons.folder_outlined
                      : Icons.inventory_2_outlined,
                  size: 16,
                ),
                title: Text(
                  artifact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                subtitle: Text(
                  '${formatBytes(artifact.sizeBytes)} · ${artifact.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '打开所在目录',
                      icon: const Icon(Icons.folder_open, size: 16),
                      onPressed: () => build.revealArtifact(artifact),
                    ),
                    if (build.previewUri != null)
                      IconButton(
                        tooltip: '在浏览器中预览',
                        icon: const Icon(Icons.public, size: 16),
                        onPressed: () => DesktopPlatform.openInBrowser(
                          build.previewUri.toString(),
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

  Widget _logCard(
    ThemeData theme,
    LocalBuildProvider build,
    LocalBuildTask task,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : const Color(0xFFE0E0E0),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
            child: Row(
              children: [
                Text(
                  '日志（${task.logs.length}）',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                IconButton(
                  tooltip: t('desktop.build.clearLogs'),
                  icon: const Icon(Icons.cleaning_services_outlined, size: 15),
                  onPressed: build.clearLogs,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 260,
            child: task.logs.isEmpty
                ? Center(child: Text('暂无日志', style: theme.textTheme.bodySmall))
                : Scrollbar(
                    controller: _logScroll,
                    child: ListView.builder(
                      controller: _logScroll,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                      itemCount: task.logs.length,
                      itemBuilder: (context, index) => Text(
                        task.logs[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _historyCard(ThemeData theme, LocalBuildProvider build) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('最近任务', style: theme.textTheme.titleSmall),
      children: [
        for (final item in build.history.take(10))
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              item.status == LocalTaskStatus.success
                  ? Icons.check_circle_outline
                  : item.status == LocalTaskStatus.cancelled
                  ? Icons.cancel_outlined
                  : Icons.error_outline,
              size: 16,
            ),
            title: Text(
              '${item.kind.label} · ${item.target.label}',
              style: theme.textTheme.bodySmall,
            ),
            subtitle: Text(
              '${item.projectPath} · ${_formatTime(item.startedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
