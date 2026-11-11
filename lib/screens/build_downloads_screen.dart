import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/git_sync_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../services/build_service.dart';
import '../services/git_host.dart';
import '../services/github_api_service.dart';

/// 云端构建产物下载页
///
/// 与构建页分离：这里列出仓库的 workflow runs，展开某次运行后
/// 读取它的 artifacts，并通过 GitHub 返回的 archive_download_url 下载。
class BuildDownloadsScreen extends StatefulWidget {
  const BuildDownloadsScreen({super.key});

  @override
  State<BuildDownloadsScreen> createState() => _BuildDownloadsScreenState();
}

class _BuildDownloadsScreenState extends State<BuildDownloadsScreen> {
  final List<WorkflowRun> _runs = [];
  final Map<int, List<RunArtifact>> _artifacts = {};
  final Set<int> _loadingArtifacts = {};
  final Set<int> _downloading = {};

  bool _loading = false;
  bool _loadingMore = false;
  String _error = '';
  int _page = 1;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  GitHubApiService? get _api => context.read<GitHubProvider>().api;

  String? get _repo {
    final link = context.read<GitSyncProvider>().currentLink;
    if (link == null || link.host != GitHost.github) return null;
    return link.repo;
  }

  Future<void> _load({bool reset = false}) async {
    final api = _api;
    final repo = _repo;
    if (api == null || repo == null) {
      setState(() {
        _error = repo == null ? '当前项目未绑定 GitHub 仓库' : '请先登录 GitHub';
        _loading = false;
      });
      return;
    }
    setState(() {
      if (reset) {
        _loading = true;
        _page = 1;
        _hasMore = true;
        _runs.clear();
        _artifacts.clear();
      } else {
        _loadingMore = true;
      }
      _error = '';
    });
    try {
      final runs = await api.listRuns(repo, page: _page, perPage: 20);
      if (!mounted) return;
      setState(() {
        _runs.addAll(runs);
        _hasMore = runs.length >= 20;
        _page += 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _toggleArtifacts(WorkflowRun run) async {
    if (_artifacts.containsKey(run.id)) {
      setState(() => _artifacts.remove(run.id));
      return;
    }
    final api = _api;
    final repo = _repo;
    if (api == null || repo == null) return;
    setState(() => _loadingArtifacts.add(run.id));
    try {
      final list = await api.listArtifacts(repo, run.id);
      if (!mounted) return;
      setState(() => _artifacts[run.id] = list);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取产物失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _loadingArtifacts.remove(run.id));
    }
  }

  BuildType _typeFor(String artifactName) {
    const prefixes = ['apk-release', 'apk-debug', 'appbundle-release', 'ios-release'];
    for (final prefix in prefixes) {
      if (artifactName == 'slipe-$prefix' || artifactName.endsWith(prefix)) {
        return BuildType.byInput(prefix) ?? BuildType.generic;
      }
    }
    return BuildType.generic;
  }

  Future<void> _download(RunArtifact artifact) async {
    final api = _api;
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (api == null) return;
    if (projectPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先打开一个项目，用于保存产物')),
      );
      return;
    }
    setState(() => _downloading.add(artifact.id));
    try {
      final bytes = await api.downloadArtifactByUrl(artifact.archiveDownloadUrl);
      final type = _typeFor(artifact.name);
      final path = await BuildService.instance.saveArtifactZip(
        bytes,
        projectPath,
        type,
      );
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('产物已下载，但未找到 ${type.artifactExt} 文件')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存到 $path'),
          backgroundColor: Colors.green,
          action: path.toLowerCase().endsWith('.apk')
              ? SnackBarAction(
                  label: '安装',
                  onPressed: () =>
                      BuildService.instance.installApk(path),
                )
              : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _downloading.remove(artifact.id));
    }
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '构建产物下载',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: _buildBody(isDark),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _runs.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 140),
          Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Text(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () => _load(reset: true),
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }
    if (_runs.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 140),
          Icon(
            Icons.inbox_outlined,
            size: 44,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无构建记录',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      itemCount: _runs.length + 1,
      itemBuilder: (context, index) {
        if (index == _runs.length) {
          if (!_hasMore) return const SizedBox(height: 8);
          return Center(
            child: TextButton(
              onPressed: _loadingMore ? null : () => _load(),
              child: Text(_loadingMore ? '加载中…' : '加载更多'),
            ),
          );
        }
        final run = _runs[index];
        final expanded = _artifacts.containsKey(run.id);
        final loading = _loadingArtifacts.contains(run.id);
        return _RunCard(
          run: run,
          isDark: isDark,
          expanded: expanded,
          loadingArtifacts: loading,
          artifacts: _artifacts[run.id] ?? const [],
          downloading: _downloading,
          onToggle: () => _toggleArtifacts(run),
          onDownload: _download,
          onOpenUrl: _openUrl,
        );
      },
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({
    required this.run,
    required this.isDark,
    required this.expanded,
    required this.loadingArtifacts,
    required this.artifacts,
    required this.downloading,
    required this.onToggle,
    required this.onDownload,
    required this.onOpenUrl,
  });

  final WorkflowRun run;
  final bool isDark;
  final bool expanded;
  final bool loadingArtifacts;
  final List<RunArtifact> artifacts;
  final Set<int> downloading;
  final VoidCallback onToggle;
  final ValueChanged<RunArtifact> onDownload;
  final ValueChanged<String> onOpenUrl;

  String _statusLabel() {
    if (!run.isCompleted) {
      return run.status == 'queued' ? '排队中' : '运行中';
    }
    switch (run.conclusion) {
      case 'success':
        return '成功';
      case 'failure':
        return '失败';
      case 'cancelled':
        return '已取消';
      case 'skipped':
        return '已跳过';
      default:
        return '已完成';
    }
  }

  Color _statusColor() {
    if (!run.isCompleted) return Colors.blueAccent;
    switch (run.conclusion) {
      case 'success':
        return Colors.green;
      case 'failure':
        return Colors.redAccent;
      case 'cancelled':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String _timeText() {
    final t = run.createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          run.name.isEmpty
                              ? '运行 #${run.runNumber}'
                              : run.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _statusLabel(),
                          style: TextStyle(fontSize: 10, color: color),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    [
                      if (run.runNumber > 0) '#${run.runNumber}',
                      if (run.headBranch.isNotEmpty) run.headBranch,
                      _timeText(),
                    ].where((e) => e.isNotEmpty).join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 10),
                    if (loadingArtifacts)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (artifacts.isEmpty)
                      Text(
                        '该次运行没有可下载的产物',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                        ),
                      )
                    else
                      for (final artifact in artifacts)
                        _ArtifactRow(
                          artifact: artifact,
                          isDark: isDark,
                          downloading: downloading.contains(artifact.id),
                          onDownload: () => onDownload(artifact),
                          onCopyUrl: () async {
                            await Clipboard.setData(
                              ClipboardData(text: artifact.archiveDownloadUrl),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制 archive_download_url'),
                                ),
                              );
                            }
                          },
                        ),
                  ],
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => onOpenUrl(run.htmlUrl),
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('在 GitHub 查看', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({
    required this.artifact,
    required this.isDark,
    required this.downloading,
    required this.onDownload,
    required this.onCopyUrl,
  });

  final RunArtifact artifact;
  final bool isDark;
  final bool downloading;
  final VoidCallback onDownload;
  final VoidCallback onCopyUrl;

  String get _sizeText {
    final bytes = artifact.sizeInBytes;
    if (bytes <= 0) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262628) : const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_zip_outlined,
            size: 20,
            color: artifact.expired
                ? Colors.grey
                : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artifact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  artifact.expired
                      ? '已过期'
                      : [
                          if (_sizeText.isNotEmpty) _sizeText,
                          'archive_download_url',
                        ].join(' · '),
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制 archive_download_url',
            visualDensity: VisualDensity.compact,
            onPressed: artifact.archiveDownloadUrl.isEmpty ? null : onCopyUrl,
            icon: const Icon(Icons.link, size: 16),
          ),
          if (downloading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: '下载',
              visualDensity: VisualDensity.compact,
              onPressed: artifact.expired ? null : onDownload,
              icon: const Icon(Icons.download_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}
