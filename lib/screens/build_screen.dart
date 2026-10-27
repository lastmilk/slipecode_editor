import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/build_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../services/build_service.dart';
import '../services/git_host.dart';
import '../services/termux_service.dart';
import '../widgets/log_console.dart';

/// 云端构建页面
///
/// GitHub：GitHub Actions（Android + iOS，macOS Runner）
/// Gitee：Gitee Go（仅 Android；无 macOS Runner 所以 iOS 禁用）
class BuildScreen extends StatefulWidget {
  const BuildScreen({super.key});

  @override
  State<BuildScreen> createState() => _BuildScreenState();
}

class _BuildScreenState extends State<BuildScreen> {
  bool _repoSetupRunning = false;
  final List<String> _repoSetupLogs = [];

  /// 当前项目使用的平台（默认 GitHub）
  GitHost _host = GitHost.github;

  // ---------------------------------------------------------------------------
  // 本地构建（Termux）
  // ---------------------------------------------------------------------------

  /// 构建模式：云端 / 本地
  bool _localBuild = false;
  bool _checkingTermux = false;
  bool _termuxInstalled = false;
  bool _termuxApiInstalled = false;
  bool _termuxHasFlutter = false;
  bool _localBuilding = false;
  String? _localArtifactPath;
  final List<String> _localLogs = [];

  @override
  void initState() {
    super.initState();
    _checkTermux();
  }

  /// 检查 Termux 环境
  Future<void> _checkTermux() async {
    setState(() => _checkingTermux = true);
    final svc = TermuxService.instance;
    _termuxInstalled = await svc.isTermuxInstalled();
    _termuxApiInstalled = await svc.isTermuxApiInstalled();
    if (_termuxInstalled) {
      _termuxHasFlutter = await svc.hasFlutter();
    }
    if (mounted) setState(() => _checkingTermux = false);
  }

  /// 本地构建（Termux）
  Future<void> _startLocalBuild() async {
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null) return;
    final buildType = context.read<BuildProvider>().type.inputValue;

    setState(() {
      _localBuilding = true;
      _localLogs.clear();
      _localArtifactPath = null;
    });

    final svc = TermuxService.instance;
    _localLog('==> 准备 Termux 本地构建环境...');

    try {
      // 1. 把项目复制到 Termux 可访问目录
      _localLog('==> 复制项目到 Termux 环境...');
      final termuxPath = await svc.prepareProject(projectPath);
      if (termuxPath == null) {
        throw '无法把项目复制到 Termux，请确认 Termux 已获取存储权限（termux-setup-storage）';
      }
      _localLog('    项目路径：$termuxPath');

      // 2. 执行 Flutter 构建
      _localLog('==> 执行 flutter build（$buildType）...');
      final result = await svc.flutterBuild(
        termuxPath,
        buildType,
        onLog: _localLog,
      );

      if (!result.isSuccess) {
        throw '构建失败（exit ${result.exitCode}）';
      }
      _localLog('==> 构建成功');

      // 3. 查找产物
      _localLog('==> 查找构建产物...');
      final artifact = await svc.findArtifact(termuxPath, buildType);
      if (artifact == null) {
        throw '未找到构建产物';
      }
      _localLog('    产物：$artifact');

      // 4. 复制回应用目录
      final localPath = await svc.copyArtifactToApp(artifact, projectPath);
      if (localPath == null) {
        throw '无法复制产物到应用目录';
      }
      _localArtifactPath = localPath;
      _localLog('==> 产物已保存：$localPath');

      // 5. 清理 Termux 临时项目
      await svc.cleanup(termuxPath);
    } catch (e) {
      _localLog('==> 失败：$e');
    } finally {
      if (mounted) setState(() => _localBuilding = false);
    }
  }

  void _localLog(String line) {
    if (!mounted) return;
    setState(() => _localLogs.add(line));
  }

  Future<void> _connect() async {
    if (_host == GitHost.github) {
      final github = context.read<GitHubProvider>();
      final ok = await github.signIn();
      if (!mounted) return;
      if (!ok && github.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：${github.error}')),
        );
      }
    } else {
      final gitee = context.read<GiteeProvider>();
      final ok = await gitee.signIn();
      if (!mounted) return;
      if (!ok && gitee.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：${gitee.error}')),
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
          title: Text('创建 ${host.label} 仓库'),
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
              Text(
                host == GitHost.github
                    ? '创建后将把当前项目代码推送到 main 分支，并注入 GitHub Actions workflow（含 iOS 构建）。'
                    : '创建后将把当前项目代码推送到 master 分支，并注入 Gitee Go 流水线（仅 Android，iOS 不可用）。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
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
      final String fullName;
      if (host == GitHost.github) {
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
        fullName = repo.fullName;
      } else {
        final repo =
            await context.read<GiteeProvider>().createRepoWithInitialPush(
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
            content: Text('✓ 仓库已创建：$fullName'),
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
    final gitee = context.watch<GiteeProvider>();
    final sync = context.watch<GitSyncProvider>();
    final projectPath = context.watch<ProjectProvider>().projectPath;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 已关联仓库时以实际平台为准，否则用用户选择的平台
    final link = sync.currentLink;
    if (link != null) _host = link.host;
    final signedIn = _host == GitHost.github ? github.isSignedIn : gitee.isSignedIn;
    final canBuild = projectPath != null &&
        signedIn &&
        link != null &&
        !build.isRunning &&
        !_repoSetupRunning;

    return Scaffold(
      appBar: AppBar(
        title: Text(_localBuild ? '本地构建' : '云端构建'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空日志',
            onPressed: _localBuild
                ? () => setState(() => _localLogs.clear())
                : build.clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          // 构建模式切换：云端 / 本地（Termux）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('云端构建'),
                  icon: Icon(Icons.cloud, size: 16),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('本地构建'),
                  icon: Icon(Icons.terminal, size: 16),
                ),
              ],
              selected: {_localBuild},
              onSelectionChanged: (v) => setState(() => _localBuild = v.first),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: _localBuild
                  ? _buildLocalSection(isDark, projectPath)
                  : _buildCloudSection(
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
          ),

          // 日志区域
          SizedBox(
            height: 240,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: LogConsole(
                lines: _localBuild ? _localLogs : build.logs,
                emptyText: _localBuild
                    ? '本地构建日志将显示在这里'
                    : '构建日志将显示在这里',
              ),
            ),
          ),
        ],
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
    return [
      // 平台选择（已关联仓库时锁定）
      if (link == null) ...[
        Text(
          '构建平台',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: GitHost.values.map((host) {
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
        login: _host == GitHost.github
            ? github.user?.login
            : gitee.user?.login,
        onConnect: _connect,
        onDisconnect: _disconnect,
      ),
      const SizedBox(height: 12),

      // 项目 / 仓库状态
      _StatusTile(
        isDark: isDark,
        ok: projectPath != null && link != null,
        title: projectPath == null
            ? '未打开项目'
            : (link == null
                ? '项目未关联 ${_host.label} 仓库'
                : '已关联仓库'),
        subtitle: projectPath == null
            ? '请先打开一个 Flutter 项目'
            : (link?.repo ?? projectPath),
        trailing: (projectPath != null &&
                link == null &&
                signedIn &&
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
                GitSyncStatus.success =>
                  '代码已自动同步到 ${link?.host.label ?? '远程仓库'}',
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
      Row(
        children: [
          Text(
            '构建类型',
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
            onSelected: build.isRunning
                ? null
                : (_) => build.setType(type),
          );
        }).toList(),
      ),
      if (!_host.supportsIosBuild)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Gitee Go 无 macOS Runner，iOS 构建已禁用；需要 iOS 产物请使用 GitHub',
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
                  ? () => build.startBuild(projectDir: projectPath!)
                  : null,
              icon: const Icon(Icons.cloud_upload),
              label: Text(
                build.isRunning
                    ? '构建中（${link?.host.ciName ?? '云端'}）...'
                    : '开始云端构建',
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
            label: Text(
              '在 ${link?.host.label ?? _host.label} 查看运行详情',
            ),
          ),
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
    ];
  }

  // ---------------------------------------------------------------------------
  // 本地构建（Termux）区块
  // ---------------------------------------------------------------------------

  List<Widget> _buildLocalSection(bool isDark, String? projectPath) {
    return [
      Text(
        'Termux 环境',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      ),
      const SizedBox(height: 8),
      if (_checkingTermux)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: CircularProgressIndicator()),
        )
      else ...[
        _StatusTile(
          isDark: isDark,
          ok: _termuxInstalled,
          title: _termuxInstalled ? 'Termux 已安装' : 'Termux 未安装',
          subtitle: _termuxInstalled
              ? 'com.termux'
              : '请从 F-Droid 安装 Termux',
        ),
        const SizedBox(height: 8),
        _StatusTile(
          isDark: isDark,
          ok: _termuxApiInstalled,
          title: _termuxApiInstalled
              ? 'Termux:API 已安装'
              : 'Termux:API 未安装',
          subtitle: _termuxApiInstalled
              ? 'com.termux.api'
              : '请从 F-Droid 安装 Termux:API 插件',
        ),
        const SizedBox(height: 8),
        _StatusTile(
          isDark: isDark,
          ok: _termuxHasFlutter,
          title: _termuxHasFlutter ? 'Flutter 已就绪' : 'Flutter 未安装',
          subtitle: _termuxHasFlutter
              ? '可在 Termux 中执行 flutter build'
              : '在 Termux 中执行：pkg install flutter',
        ),
      ],
      const SizedBox(height: 16),

      // 构建类型
      Row(
        children: [
          Text(
            '构建类型',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          BuildType.apkRelease,
          BuildType.apkDebug,
          BuildType.appBundleRelease,
        ].map((type) {
          final build = context.read<BuildProvider>();
          final selected = build.type == type;
          return ChoiceChip(
            label: Text(type.label),
            selected: selected,
            onSelected: _localBuilding
                ? null
                : (_) => build.setType(type),
          );
        }).toList(),
      ),
      const SizedBox(height: 16),

      // 本地构建按钮
      FilledButton.icon(
        onPressed: (_termuxInstalled &&
                _termuxHasFlutter &&
                projectPath != null &&
                !_localBuilding)
            ? _startLocalBuild
            : null,
        icon: _localBuilding
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.build),
        label: Text(_localBuilding ? '构建中...' : '开始本地构建'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          minimumSize: const Size.fromHeight(48),
        ),
      ),

      if (!_termuxInstalled) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '本地构建需要在手机上安装 Termux 并配置 Flutter 环境。'
            '安装后在 Termux 中执行 termux-setup-storage 获取存储权限，'
            '再执行 pkg install flutter 安装 Flutter。',
            style: TextStyle(fontSize: 11, height: 1.5),
          ),
        ),
      ],

      // 本地产物
      if (_localArtifactPath != null) ...[
        const SizedBox(height: 16),
        _ArtifactCard(
          path: _localArtifactPath!,
          isDark: isDark,
          platformLabel: 'Termux 本地',
          onInstall: () async {
            final ok = await BuildService.instance
                .installApk(_localArtifactPath!);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(ok
                    ? '已调用系统安装器'
                    : '无法安装，请检查产物'),
              ),
            );
          },
          onCopy: () {
            Clipboard.setData(
              ClipboardData(text: _localArtifactPath!),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('路径已复制')),
            );
          },
        ),
      ],
      const SizedBox(height: 20),
      const Text(
        '执行日志',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ];
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
                      ? '已连接 ${host.label}：${login ?? ''}'
                      : (configured ? '未连接 ${host.label}' : '未配置 ${host.label}'),
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
                              ? 'OAuth 授权（PKCE）已完成'
                              : 'OAuth 授权已完成（token 由账号后端换取）')
                          : '通过 OAuth 授权后才能创建仓库与云端构建')
                      : (host == GitHost.github
                          ? '请在 .env 中填写 GITHUB_CLIENT_ID 后重启应用'
                          : 'Gitee 需要 GITEE_CLIENT_ID + 账号后端（后端换 token）'),
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
              onPressed: signingIn ? null : (signedIn ? onDisconnect : onConnect),
              child: Text(
                signingIn ? '授权中...' : (signedIn ? '断开' : '连接'),
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
                  '构建产物（已从 $platformLabel 下载）',
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
