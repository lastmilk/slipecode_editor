import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../providers/build_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../services/git_host.dart';
import '../services/github_api_service.dart' show WorkflowJob, WorkflowStep;
import '../widgets/log_console.dart';

/// 云端构建页面
///
/// GitHub：GitHub Actions（Android + iOS，macOS Runner）
/// Gitee：Gitee Go（仅 Android；无 macOS Runner 所以 iOS 禁用）
class BuildScreen extends StatefulWidget {
  const BuildScreen({super.key});

  /// 构建功能入口守卫：GitHub / Gitee 均未登录时弹窗提醒并返回 false。
  ///
  /// 进入构建页面前调用；已登录任一平台则直接放行。
  static Future<bool> ensureSignedIn(BuildContext context) async {
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    if (github.isSignedIn || gitee.isSignedIn) return true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要配置 Git 平台账号'),
        content: const Text(
          '云端构建依赖 GitHub Actions / Gitee Go，'
          '需要登录 GitHub 或 Gitee 账号才能使用。\n'
          '请先在首页底部或账号页完成登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return false;
  }

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> {
  bool _repoSetupRunning = false;
  final List<String> _repoSetupLogs = [];

  /// 当前项目使用的平台（默认 GitHub）
  GitHost _host = GitHost.github;

  @override
  void initState() {
    super.initState();
    // 从服务端恢复构建进度（退出 IDE 后由服务端持续监听）
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromServer());
  }

  Future<void> _syncFromServer() async {
    if (!mounted) return;
    final build = context.read<BuildProvider>();
    final projectPath = context.read<ProjectProvider>().projectPath;
    unawaited(build.syncFromServer(projectDir: projectPath));
  }

  Future<void> _connect() async {
    if (_host == GitHost.github) {
      final github = context.read<GitHubProvider>();
      final ok = await github.signIn();
      if (!mounted) return;
      if (!ok && github.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('build.connectFailed', {'error': '${github.error}'}),
            ),
          ),
        );
      }
    } else {
      final gitee = context.read<GiteeProvider>();
      final ok = await gitee.signIn();
      if (!mounted) return;
      if (!ok && gitee.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('build.connectFailed', {'error': '${gitee.error}'}),
            ),
          ),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    if (_host == GitHost.github) {
      await context.read<GitHubProvider>().signOut();
    } else {
      await context.read<GiteeProvider>().signOut();
    }
  }

  /// 为当前项目创建仓库并做初始推送
  Future<void> _createRepoForProject() async {
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null) return;
    final defaultName = projectPath.split(RegExp(r'[/\\]')).last;
    final host = _host;

    final nameController = TextEditingController(text: defaultName);
    var isPrivate = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(t('build.createRepoTitle', {'host': host.label})),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: t('build.repoNameLabel'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: isPrivate,
                onChanged: (v) => setDialogState(() => isPrivate = v),
                title: Text(t('build.privateRepo')),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 4),
              Text(
                host == GitHost.github
                    ? t('build.repoHintGithub')
                    : t('build.repoHintGitee'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('build.createAndPush')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final repoName = nameController.text.trim();
    if (repoName.isEmpty) return;

    setState(() {
      _repoSetupRunning = true;
      _repoSetupLogs.clear();
    });

    try {
      final String fullName;
      if (host == GitHost.github) {
        final repo = await context
            .read<GitHubProvider>()
            .createRepoWithInitialPush(
              projectPath,
              repoName,
              private: isPrivate,
              onLog: (line) {
                if (mounted) {
                  setState(() => _repoSetupLogs.add(line));
                }
              },
            );
        fullName = repo.fullName;
      } else {
        final repo = await context
            .read<GiteeProvider>()
            .createRepoWithInitialPush(
              projectPath,
              repoName,
              private: isPrivate,
              onLog: (line) {
                if (mounted) {
                  setState(() => _repoSetupLogs.add(line));
                }
              },
            );
        fullName = repo.fullName;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('build.repoCreated', {'name': fullName})),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _repoSetupLogs.add('==> ${t('build.failed', {'error': '$e'})}');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('build.createRepoFailed', {'error': '$e'})),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _repoSetupRunning = false);
    }
  }

  Future<void> _installArtifact() async {
    final provider = context.read<BuildProvider>();
    final ok = await provider.installArtifact();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? t('build.installerLaunched') : t('build.installFailed'),
        ),
      ),
    );
  }

  /// 启动构建：初始化阶段显示遮罩弹窗，run 创建后自动关闭并展示实际构建进程
  Future<void> _startBuild(String projectPath) async {
    final build = context.read<BuildProvider>();
    final navigator = Navigator.of(context, rootNavigator: true);
    var closed = false;
    void closeDialog() {
      if (closed) return;
      closed = true;
      navigator.pop();
    }

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BuildInitDialog(provider: build),
      ).whenComplete(() => closed = true),
    );

    unawaited(
      build.startBuild(projectDir: projectPath).then((_) {
        if (!mounted) return;
        if (build.status == BuildStatus.failed && build.error.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(build.error),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }).whenComplete(closeDialog),
    );

    // 初始化完成（run 已创建）后自动关闭弹窗
    while (mounted && build.isInitializing) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (mounted) closeDialog();
  }

  @override
  Widget build(BuildContext context) {
    final build = context.watch<BuildProvider>();
    final github = context.watch<GitHubProvider>();
    final gitee = context.watch<GiteeProvider>();
    final sync = context.watch<GitSyncProvider>();
    final projectPath = context.watch<ProjectProvider>().projectPath;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 已关联仓库时以实际平台为准，否则用用户选择的平台
    final link = sync.currentLink;
    if (link != null) _host = link.host;
    final signedIn = _host == GitHost.github
        ? github.isSignedIn
        : gitee.isSignedIn;
    final canBuild =
        projectPath != null &&
        signedIn &&
        link != null &&
        !build.isRunning &&
        !_repoSetupRunning;

    return Scaffold(
      appBar: AppBar(title: Text(t('build.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: _buildCloudSection(
          isDark,
          build,
          github,
          gitee,
          sync,
          link,
          signedIn,
          canBuild,
          projectPath,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 云端构建区块
  // ---------------------------------------------------------------------------

  List<Widget> _buildCloudSection(
    bool isDark,
    BuildProvider build,
    GitHubProvider github,
    GiteeProvider gitee,
    GitSyncProvider sync,
    GitLink? link,
    bool signedIn,
    bool canBuild,
    String? projectPath,
  ) {
    // 仅展示已登录的平台选项（未登录的平台隐藏）
    final signedInHosts = <GitHost>[
      if (github.isSignedIn) GitHost.github,
      if (gitee.isSignedIn) GitHost.gitee,
    ];
    if (link == null &&
        signedInHosts.isNotEmpty &&
        !signedInHosts.contains(_host)) {
      _host = signedInHosts.first;
    }

    return [
      // 平台选择（已关联仓库时锁定）
      if (link == null && signedInHosts.isNotEmpty) ...[
        Text(
          t('build.platform'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: signedInHosts.map((host) {
            return ChoiceChip(
              label: Text(host.label),
              selected: _host == host,
              onSelected: build.isRunning
                  ? null
                  : (_) => setState(() => _host = host),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
      ],

      // 平台账号状态
      _HostAccountCard(
        isDark: isDark,
        host: _host,
        configured: _host == GitHost.github
            ? github.isConfigured
            : gitee.isConfigured,
        signedIn: signedIn,
        signingIn: _host == GitHost.github
            ? github.status == GitHubAuthStatus.signingIn
            : gitee.status == GiteeAuthStatus.signingIn,
        login: _host == GitHost.github ? github.user?.login : gitee.user?.login,
        onConnect: _connect,
        onDisconnect: _disconnect,
      ),
      const SizedBox(height: 12),

      // 项目 / 仓库状态
      _StatusTile(
        isDark: isDark,
        ok: projectPath != null && link != null,
        title: projectPath == null
            ? t('build.noProject')
            : (link == null
                  ? t('build.repoNotLinked', {'host': _host.label})
                  : t('build.repoLinked')),
        subtitle: projectPath == null
            ? t('build.openProjectFirst')
            : (link?.repo ?? projectPath),
        trailing:
            (projectPath != null &&
                link == null &&
                signedIn &&
                !_repoSetupRunning)
            ? TextButton(
                onPressed: _createRepoForProject,
                child: Text(t('build.createRepo')),
              )
            : null,
      ),

      // 仓库创建进度
      if (_repoSetupLogs.isNotEmpty) ...[
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          child: LogConsole(lines: _repoSetupLogs, emptyText: '', fontSize: 11),
        ),
      ],
      const SizedBox(height: 16),

      // 同步状态
      Row(
        children: [
          Icon(
            switch (sync.status) {
              GitSyncStatus.idle => Icons.cloud_done_outlined,
              GitSyncStatus.pending => Icons.cloud_upload_outlined,
              GitSyncStatus.syncing => Icons.cloud_upload,
              GitSyncStatus.success => Icons.cloud_done,
              GitSyncStatus.error => Icons.cloud_off,
            },
            size: 16,
            color: sync.status == GitSyncStatus.error
                ? Colors.redAccent
                : Colors.blueAccent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              switch (sync.status) {
                GitSyncStatus.idle => t('build.syncIdle'),
                GitSyncStatus.pending => t('build.syncPending', {
                  'count': '${sync.pendingCount}',
                }),
                GitSyncStatus.syncing => t('build.syncing', {
                  'count': '${sync.pendingCount}',
                }),
                GitSyncStatus.success => t('build.syncDone', {
                  'target': link?.host.label ?? t('build.remoteRepo'),
                }),
                GitSyncStatus.error => t('build.syncFailed', {
                  'error': sync.error ?? '',
                }),
              },
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (sync.pendingCount > 0)
            TextButton(
              onPressed: sync.syncNow,
              child: Text(t('build.syncNow')),
            ),
        ],
      ),
      const SizedBox(height: 16),

      // 构建失败提示
      if (!build.isRunning && build.error.isNotEmpty) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Text(
            build.error,
            style: const TextStyle(fontSize: 12, color: Colors.redAccent),
          ),
        ),
        const SizedBox(height: 12),
      ],

      // 构建类型
      Row(
        children: [
          Text(
            t('build.type'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const Spacer(),
          Text(
            _host.ciName,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: build.availableTypes.map((type) {
          final selected = build.type == type;
          return ChoiceChip(
            label: Text(type.label),
            selected: selected,
            onSelected: build.isRunning ? null : (_) => build.setType(type),
          );
        }).toList(),
      ),
      if (!_host.supportsIosBuild)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            t('build.iosDisabledHint'),
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ),
      const SizedBox(height: 16),

      // 构建按钮
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: canBuild
                  ? () => _startBuild(projectPath!)
                  : null,
              icon: const Icon(Icons.cloud_upload),
              label: Text(
                build.isRunning
                    ? t('build.running', {
                        'ci': link?.host.ciName ?? t('build.cloud'),
                      })
                    : t('build.start'),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (build.isRunning) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: build.cancel,
              icon: const Icon(Icons.stop),
              label: Text(t('common.cancel')),
            ),
          ],
        ],
      ),
      if (build.runUrl.isNotEmpty) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(build.runUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(
              t('build.viewRun', {'host': link?.host.label ?? _host.label}),
            ),
          ),
        ),
      ],

      // 完整 workflow 构建流程（Job / Step 实时状态）
      if (build.jobs.isNotEmpty || build.isRunning) ...[
        const SizedBox(height: 16),
        _WorkflowCard(
          isDark: isDark,
          jobs: build.jobs,
          running: build.isRunning,
          onCancel: build.cancel,
        ),
      ],

      // 产物
      if (build.artifactPath != null) ...[
        const SizedBox(height: 16),
        _ArtifactCard(
          path: build.artifactPath!,
          isDark: isDark,
          platformLabel: link?.host.label ?? _host.label,
          onInstall: _installArtifact,
          onCopy: () {
            Clipboard.setData(ClipboardData(text: build.artifactPath!));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t('build.pathCopied'))),
            );
          },
        ),
      ],
      const SizedBox(height: 20),

      Row(
        children: [
          Text(
            build.currentTask.isEmpty ? t('build.runLogs') : build.currentTask,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const Spacer(),
          if (build.duration != null)
            Text(
              '${build.duration!.inSeconds}s',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
        ],
      ),
    ];
  }
}

class _WorkflowCard extends StatelessWidget {
  final bool isDark;
  final List<WorkflowJob> jobs;
  final bool running;
  final Future<void> Function() onCancel;

  const _WorkflowCard({
    required this.isDark,
    required this.jobs,
    required this.running,
    required this.onCancel,
  });

  static String _durationText(WorkflowStep step) {
    final d = step.duration;
    if (d == null) return t('build.unknown');
    if (d.inMinutes > 0) {
      return t('build.durationMinutes', {
        'minutes': '${d.inMinutes}',
        'seconds': '${d.inSeconds % 60}',
      });
    }
    return t('build.durationSeconds', {'seconds': '${d.inSeconds}'});
  }

  static Widget _stepIcon(WorkflowStep step) {
    if (step.isRunning) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: Color(0xFFE3B341),
          ),
        ),
      );
    }
    if (step.isCompleted) {
      if (step.isSuccess) {
        return const Icon(
          Icons.check_circle,
          color: Color(0xFF1F883D),
          size: 26,
        );
      }
      return Icon(
        step.conclusion == 'cancelled'
            ? Icons.cancel
            : (step.conclusion == 'skipped'
                  ? Icons.remove_circle
                  : Icons.error),
        color: const Color(0xFFCF222E),
        size: 26,
      );
    }
    return const Icon(Icons.schedule, color: Color(0xFFE3B341), size: 24);
  }

  static String _stepSubtitle(WorkflowStep step) {
    if (step.isRunning) return t('build.stepRunning');
    if (!step.isCompleted) return t('build.unknown');
    final d = step.duration;
    if (d == null) return t('build.stepCompleted');
    return _durationText(step);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = isDark
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFE4E7EB);
    final bg = isDark ? const Color(0xFF252526) : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (jobs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  t('build.waitingRun'),
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            )
          else
            for (final job in jobs) ...[
              if (jobs.length > 1)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  color: isDark
                      ? const Color(0xFF1F1F1F)
                      : const Color(0xFFF6F8FA),
                  child: Text(
                    job.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              for (var i = 0; i < job.steps.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: borderColor),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      _stepIcon(job.steps[i]),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              job.steps[i].name,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: job.steps[i].isRunning
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color:
                                    job.steps[i].isRunning ||
                                        !job.steps[i].isCompleted
                                    ? (isDark ? Colors.white70 : Colors.black54)
                                    : (isDark ? Colors.white : Colors.black87),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _stepSubtitle(job.steps[i]),
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          if (running) ...[
            Divider(height: 1, thickness: 1, color: borderColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onCancel,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFCF222E),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(t('build.cancelWorkflow')),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HostAccountCard extends StatelessWidget {
  final bool isDark;
  final GitHost host;
  final bool configured;
  final bool signedIn;
  final bool signingIn;
  final String? login;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _HostAccountCard({
    required this.isDark,
    required this.host,
    required this.configured,
    required this.signedIn,
    required this.signingIn,
    required this.login,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final ok = signedIn;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252526) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (ok ? Colors.green : Colors.orange).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            signedIn ? Icons.check_circle : Icons.account_circle_outlined,
            color: ok ? Colors.green : Colors.orange,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  signedIn
                      ? t('build.connectedAs', {
                          'host': host.label,
                          'login': login ?? '',
                        })
                      : (configured
                            ? t('build.notConnected', {'host': host.label})
                            : t('build.notConfigured', {'host': host.label})),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  configured
                      ? (signedIn
                            ? (host == GitHost.github
                                  ? t('build.oauthPkceDone')
                                  : t('build.oauthDone'))
                            : t('build.oauthRequired'))
                      : (host == GitHost.github
                            ? t('build.needGithubClientId')
                            : t('build.needGiteeConfig')),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
              ],
            ),
          ),
          if (configured)
            TextButton(
              onPressed: signingIn
                  ? null
                  : (signedIn ? onDisconnect : onConnect),
              child: Text(
                signingIn
                    ? t('build.authorizing')
                    : (signedIn
                          ? t('build.disconnect')
                          : t('build.connect')),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final bool isDark;
  final bool ok;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _StatusTile({
    required this.isDark,
    required this.ok,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252526) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.warning_amber_rounded,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  final String path;
  final bool isDark;
  final String platformLabel;
  final VoidCallback onInstall;
  final VoidCallback onCopy;

  const _ArtifactCard({
    required this.path,
    required this.isDark,
    required this.platformLabel,
    required this.onInstall,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2A1F) : const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t('build.artifactTitle', {'platform': platformLabel}),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            path,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 16),
                label: Text(t('build.copyPath')),
              ),
              const SizedBox(width: 8),
              if (path.endsWith('.apk'))
                FilledButton.tonalIcon(
                  onPressed: onInstall,
                  icon: const Icon(Icons.install_mobile, size: 16),
                  label: Text(t('build.install')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 构建初始化遮罩弹窗
///
/// 代码同步 + 触发云端构建期间展示，run 创建后由调用方自动关闭，
/// 之后页面展示实际的 Job / Step 构建进程。
class _BuildInitDialog extends StatelessWidget {
  const _BuildInitDialog({required this.provider});

  final BuildProvider provider;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: AnimatedBuilder(
          animation: provider,
          builder: (context, _) {
            final task = provider.currentTask;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 18),
                const Text(
                  '正在初始化构建，请勿退出应用…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                if (task.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    task,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 6),
                const Text(
                  '正在比对并同步代码、触发云端构建',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: provider.cancel,
                  child: const Text('取消构建'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
