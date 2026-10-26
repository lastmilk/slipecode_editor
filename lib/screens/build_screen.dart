import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/build_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../services/build_service.dart';
import '../widgets/log_console.dart';

/// 云端构建页面
///
/// 基于 GitHub Actions：连接 GitHub → 关联仓库 → 触发云端构建 → 下载产物
class BuildScreen extends StatefulWidget {
  const BuildScreen({super.key});

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> {
  bool _repoSetupRunning = false;
  final List<String> _repoSetupLogs = [];

  Future<void> _connectGitHub() async {
    final github = context.read<GitHubProvider>();
    final ok = await github.signIn();
    if (!mounted) return;
    if (!ok && github.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败：${github.error}')),
      );
    }
  }

  Future<void> _disconnectGitHub() async {
    await context.read<GitHubProvider>().signOut();
  }

  /// 为当前项目创建仓库并做初始推送
  Future<void> _createRepoForProject() async {
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null) return;
    final defaultName = projectPath.split(RegExp(r'[/\\]')).last;

    final nameController = TextEditingController(text: defaultName);
    var isPrivate = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('创建 GitHub 仓库'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '仓库名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: isPrivate,
                onChanged: (v) => setDialogState(() => isPrivate = v),
                title: const Text('私有仓库'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 4),
              const Text(
                '创建后将把当前项目代码推送到 main 分支，并注入 GitHub Actions 构建 workflow。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建并推送'),
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
      final repo =
          await context.read<GitHubProvider>().createRepoWithInitialPush(
                projectPath,
                repoName,
                private: isPrivate,
                onLog: (line) {
                  if (mounted) {
                    setState(() => _repoSetupLogs.add(line));
                  }
                },
              );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ 仓库已创建：${repo.fullName}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _repoSetupLogs.add('==> 失败：$e'));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$e'), backgroundColor: Colors.red),
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
        content: Text(ok ? '已调用系统安装器' : '无法安装，请检查产物或使用文件管理器安装'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final build = context.watch<BuildProvider>();
    final github = context.watch<GitHubProvider>();
    final sync = context.watch<GitSyncProvider>();
    final projectPath = context.watch<ProjectProvider>().projectPath;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final repo = projectPath == null ? null : github.repoFor(projectPath);
    final canBuild = projectPath != null &&
        github.isSignedIn &&
        repo != null &&
        !build.isRunning &&
        !_repoSetupRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('云端构建'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空日志',
            onPressed: build.clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // GitHub 账号状态
                _GitHubAccountCard(
                  isDark: isDark,
                  github: github,
                  onConnect: _connectGitHub,
                  onDisconnect: _disconnectGitHub,
                ),
                const SizedBox(height: 12),

                // 项目 / 仓库状态
                _StatusTile(
                  isDark: isDark,
                  ok: projectPath != null && repo != null,
                  title: projectPath == null
                      ? '未打开项目'
                      : (repo == null ? '项目未关联 GitHub 仓库' : '已关联仓库'),
                  subtitle: projectPath == null
                      ? '请先打开一个 Flutter 项目'
                      : (repo ?? projectPath),
                  trailing: (projectPath != null &&
                          repo == null &&
                          github.isSignedIn &&
                          !_repoSetupRunning)
                      ? TextButton(
                          onPressed: _createRepoForProject,
                          child: const Text('创建仓库'),
                        )
                      : null,
                ),

                // 仓库创建进度
                if (_repoSetupLogs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: LogConsole(
                      lines: _repoSetupLogs,
                      emptyText: '',
                      fontSize: 11,
                    ),
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
                          GitSyncStatus.idle => '代码已同步',
                          GitSyncStatus.pending =>
                            '有 ${sync.pendingCount} 个文件待同步（自动推送中）',
                          GitSyncStatus.syncing =>
                            '正在同步 ${sync.pendingCount} 个文件...',
                          GitSyncStatus.success => '代码已自动同步到 GitHub',
                          GitSyncStatus.error => '同步失败：${sync.error ?? ''}',
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
                        child: const Text('立即同步'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                // 构建类型
                Text(
                  '构建类型',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: BuildType.values.map((type) {
                    final selected = build.type == type;
                    return ChoiceChip(
                      label: Text(type.label),
                      selected: selected,
                      onSelected: build.isRunning
                          ? null
                          : (_) => build.setType(type),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // 构建按钮
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: canBuild
                            ? () => build.startBuild(projectDir: projectPath)
                            : null,
                        icon: const Icon(Icons.cloud_upload),
                        label: Text(
                          build.isRunning ? '构建中（云端）...' : '开始云端构建',
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
                        label: const Text('取消'),
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
                      label: const Text('在 GitHub 查看运行详情'),
                    ),
                  ),
                ],

                // 产物
                if (build.artifactPath != null) ...[
                  const SizedBox(height: 16),
                  _ArtifactCard(
                    path: build.artifactPath!,
                    isDark: isDark,
                    onInstall: _installArtifact,
                    onCopy: () {
                      Clipboard.setData(
                        ClipboardData(text: build.artifactPath!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('路径已复制')),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 20),

                Row(
                  children: [
                    Text(
                      build.currentTask.isEmpty ? '执行日志' : build.currentTask,
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
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // 日志区域
          SizedBox(
            height: 240,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: LogConsole(
                lines: build.logs,
                emptyText: '构建日志将显示在这里',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GitHubAccountCard extends StatelessWidget {
  final bool isDark;
  final GitHubProvider github;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _GitHubAccountCard({
    required this.isDark,
    required this.github,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final notConfigured = !github.isConfigured;
    final signedIn = github.isSignedIn;
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
                      ? '已连接 GitHub：${github.user?.login ?? ''}'
                      : (notConfigured ? '未配置 GitHub Client ID' : '未连接 GitHub'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  notConfigured
                      ? '请在 .env 中填写 GITHUB_CLIENT_ID 后重启应用'
                      : (signedIn
                          ? 'OAuth 授权（PKCE）已完成'
                          : '通过 OAuth 授权后才能创建仓库与云端构建'),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
              ],
            ),
          ),
          if (!notConfigured)
            TextButton(
              onPressed: github.status == GitHubAuthStatus.signingIn
                  ? null
                  : (signedIn ? onDisconnect : onConnect),
              child: Text(
                github.status == GitHubAuthStatus.signingIn
                    ? '授权中...'
                    : (signedIn ? '断开' : '连接'),
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
  final VoidCallback onInstall;
  final VoidCallback onCopy;

  const _ArtifactCard({
    required this.path,
    required this.isDark,
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
          const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 18),
              SizedBox(width: 6),
              Text(
                '构建产物（已从 GitHub Actions 下载）',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
                label: const Text('复制路径'),
              ),
              const SizedBox(width: 8),
              if (path.endsWith('.apk'))
                FilledButton.tonalIcon(
                  onPressed: onInstall,
                  icon: const Icon(Icons.install_mobile, size: 16),
                  label: const Text('安装'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
