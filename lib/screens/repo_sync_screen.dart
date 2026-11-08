import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/sync_repo.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../services/git_client_service.dart';
import '../services/gitee_api_service.dart';
import '../services/git_host.dart';
import '../services/github_api_service.dart';
import '../services/project_history_service.dart';

/// 从 GitHub / Gitee 拉取通过 SLIPE 创建的仓库
class RepoSyncScreen extends StatefulWidget {
  const RepoSyncScreen({super.key});

  @override
  State<RepoSyncScreen> createState() => _RepoSyncScreenState();
}

class _RepoSyncScreenState extends State<RepoSyncScreen> {
  final Map<GitHost, List<SyncRepo>> _repos = {};
  final Set<String> _selected = {};
  final Map<String, String> _results = {};

  bool _loading = false;
  bool _syncing = false;
  String? _error;
  String? _projectsRoot;
  String? _syncingLabel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    setState(() {
      _loading = true;
      _error = null;
      _repos.clear();
      _selected.clear();
    });

    final errors = <String>[];
    final repos = <GitHost, List<SyncRepo>>{};

    if (github.isSignedIn && github.token != null) {
      try {
        final list = await GitHubApiService(github.token!).listSlipeRepos();
        repos[GitHost.github] = list
            .map(
              (r) => SyncRepo(
                host: GitHost.github,
                fullName: r.fullName,
                defaultBranch: r.defaultBranch,
                htmlUrl: r.htmlUrl,
                private: r.private,
              ),
            )
            .toList();
      } catch (e) {
        errors.add('GitHub：$e');
      }
    }

    if (gitee.isSignedIn && gitee.token != null) {
      try {
        final list = await GiteeApiService(gitee.token!).listSlipeRepos();
        repos[GitHost.gitee] = list
            .map(
              (r) => SyncRepo(
                host: GitHost.gitee,
                fullName: r.fullName,
                defaultBranch: r.defaultBranch,
                htmlUrl: r.htmlUrl,
                private: r.private,
              ),
            )
            .toList();
      } catch (e) {
        errors.add('Gitee：$e');
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _repos.addAll(repos);
      _projectsRoot = p.join(docs.path, 'Projects');
      _error = errors.isEmpty ? null : errors.join('\n');
    });
  }

  Future<void> _signIn(GitHost host) async {
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = host == GitHost.github
        ? await github.signIn()
        : await gitee.signIn();
    if (!mounted) return;
    if (!ok) {
      final error = host == GitHost.github ? github.error : gitee.error;
      messenger.showSnackBar(
        SnackBar(
          content: Text('${host.label} 登录失败：${error ?? '未知错误'}'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    await _reload();
  }

  void _toggle(SyncRepo repo, bool value) {
    setState(() {
      if (value) {
        _selected.add(repo.key);
      } else {
        _selected.remove(repo.key);
      }
    });
  }

  Future<void> _startSync() async {
    final github = context.read<GitHubProvider>();
    final gitee = context.read<GiteeProvider>();
    final root = _projectsRoot;
    if (root == null) return;

    final targets = <SyncRepo>[
      for (final entry in _repos.entries)
        for (final repo in entry.value)
          if (_selected.contains(repo.key)) repo,
    ];
    if (targets.isEmpty) return;

    setState(() {
      _syncing = true;
      _results.clear();
    });

    for (var i = 0; i < targets.length; i++) {
      final repo = targets[i];
      if (!mounted) return;
      setState(() {
        _syncingLabel =
            '正在拉取 ${repo.host.label} · ${repo.fullName}（${i + 1}/${targets.length}）';
      });

      final token = repo.host == GitHost.github ? github.token : gitee.token;
      if (token == null || token.isEmpty) {
        setState(() => _results[repo.key] = '未登录 ${repo.host.label} 账号');
        continue;
      }

      try {
        final dest = GitClientService.instance.resolveDestPath(root, repo);
        final outcome = await GitClientService.instance.syncRepo(
          repo,
          destPath: dest,
          token: token,
        );
        // 记入项目历史，并绑定远程仓库，方便后续推送 / 构建
        await ProjectHistoryService.instance.touch(outcome.path, name: repo.name);
        if (repo.host == GitHost.github) {
          await github.linkRepo(outcome.path, repo.fullName);
        } else {
          await gitee.linkRepo(outcome.path, repo.fullName);
        }
        if (!mounted) return;
        setState(() {
          _results[repo.key] = outcome.cloned ? '已克隆到本地' : '已更新到最新';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _results[repo.key] = '失败：$e');
      }
    }

    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncingLabel = null;
    });
    final failed = _results.values.where((v) => v.startsWith('失败')).length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '同步完成：${targets.length} 个仓库已拉取到本地'
              : '同步完成：${targets.length - failed} 成功，$failed 失败',
        ),
        backgroundColor: failed == 0 ? Colors.green : Colors.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final github = context.watch<GitHubProvider>();
    final gitee = context.watch<GiteeProvider>();
    final selectedCount = _selected.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('同步仓库'),
        actions: [
          IconButton(
            tooltip: '刷新仓库列表',
            onPressed: _loading || _syncing ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                Text(
                  '选择需要拉取到本地的仓库。未登录的平台需先登录账号。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorCard(message: _error!, onRetry: _reload),
                ],
                const SizedBox(height: 8),
                _hostSection(GitHost.github, github, gitee),
                const SizedBox(height: 8),
                _hostSection(GitHost.gitee, github, gitee),
              ],
            ),
      bottomNavigationBar: _syncing || selectedCount > 0
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_syncing) ...[
                      LinearProgressIndicator(),
                      const SizedBox(height: 6),
                      Text(
                        _syncingLabel ?? '正在同步…',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton.icon(
                      onPressed: _syncing || selectedCount == 0
                          ? null
                          : _startSync,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: Text(
                        _syncing ? '同步中…' : '开始同步（$selectedCount）',
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _hostSection(
    GitHost host,
    GitHubProvider github,
    GiteeProvider gitee,
  ) {
    final isSignedIn = host == GitHost.github
        ? github.isSignedIn
        : gitee.isSignedIn;
    final login = host == GitHost.github ? github.user?.login : gitee.user?.login;
    final repos = _repos[host] ?? const <SyncRepo>[];

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              host == GitHost.github ? Icons.code : Icons.hub_outlined,
            ),
            title: Text('${host.label} 仓库'),
            subtitle: Text(
              isSignedIn ? '@${login ?? '已登录'}' : '未登录',
            ),
            trailing: isSignedIn
                ? null
                : TextButton(
                    onPressed: _syncing ? null : () => _signIn(host),
                    child: Text('登录 ${host.label}'),
                  ),
          ),
          if (!isSignedIn)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                '请先登录 ${host.label} 账号，登录后才能读取你在 ${host.label} '
                '上通过 SLIPE 创建的仓库。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else if (repos.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                '暂无通过 SLIPE 创建的 ${host.label} 仓库。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else ...[
            const Divider(height: 1),
            for (final repo in repos)
              CheckboxListTile(
                value: _selected.contains(repo.key),
                onChanged: _syncing
                    ? null
                    : (value) => _toggle(repo, value ?? false),
                dense: true,
                title: Text(
                  repo.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _results[repo.key] ??
                      '${repo.defaultBranch} · ${repo.private ? '私有' : '公开'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _results[repo.key]?.startsWith('失败') == true
                      ? const TextStyle(color: Colors.redAccent)
                      : null,
                ),
                secondary: const Icon(Icons.folder_shared_outlined),
              ),
          ],
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
