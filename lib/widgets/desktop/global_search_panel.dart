import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/project_search_service.dart';

/// 侧边栏全局搜索：ripgrep 优先，支持大小写/正则与批量替换。
class GlobalSearchPanel extends StatefulWidget {
  final String rootPath;
  final void Function(String path, int line) onOpen;

  const GlobalSearchPanel({
    super.key,
    required this.rootPath,
    required this.onOpen,
  });

  @override
  State<GlobalSearchPanel> createState() => _GlobalSearchPanelState();
}

class _GlobalSearchPanelState extends State<GlobalSearchPanel> {
  final ProjectSearchService _service = ProjectSearchService();
  final TextEditingController _query = TextEditingController();
  final TextEditingController _replacement = TextEditingController();

  ProjectSearchResult? _result;
  bool _loading = false;
  bool _caseSensitive = false;
  bool _useRegex = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _query.text.trim();
    if (query.isEmpty) {
      setState(() {
        _result = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.search(
        widget.rootPath,
        query,
        caseSensitive: _caseSensitive,
        regex: _useRegex,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _replaceAll() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('desktop.search.replaceAll')),
        content: Text(
          '${t('desktop.search.replaceAll')}: "$query" → "${_replacement.text}"',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await _service.replaceAll(
      widget.rootPath,
      query,
      _replacement.text,
      caseSensitive: _caseSensitive,
      regex: _useRegex,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$count × ${t('desktop.search.replaceAll')}')),
    );
    await _runSearch();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = <String, List<ProjectSearchMatch>>{};
    for (final match in _result?.matches ?? const <ProjectSearchMatch>[]) {
      grouped.putIfAbsent(match.path, () => []).add(match);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Column(
            children: [
              TextField(
                controller: _query,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: t('desktop.search.placeholder'),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  suffixIcon: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          onPressed: _runSearch,
                        ),
                ),
                onSubmitted: (_) => _runSearch(),
              ),
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    tooltip: 'Aa',
                    isSelected: _caseSensitive,
                    icon: const Icon(Icons.text_fields),
                    onPressed: () {
                      setState(() => _caseSensitive = !_caseSensitive);
                      _runSearch();
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    tooltip: '.*',
                    isSelected: _useRegex,
                    icon: const Icon(Icons.code),
                    onPressed: () {
                      setState(() => _useRegex = !_useRegex);
                      _runSearch();
                    },
                  ),
                  const Spacer(),
                  if (_result != null)
                    Text(
                      '${_result!.matches.length}'
                      '${_result!.truncated ? '+' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              TextField(
                controller: _replacement,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: t('desktop.action.replace'),
                  prefixIcon: const Icon(Icons.find_replace, size: 16),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.done_all, size: 16),
                    tooltip: t('desktop.search.replaceAll'),
                    onPressed: _replaceAll,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                )
              : grouped.isEmpty
              ? Center(
                  child: Text(
                    _result == null
                        ? t('desktop.search.placeholder')
                        : t('desktop.search.noResults'),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final entry in grouped.entries)
                      _FileGroup(
                        rootPath: widget.rootPath,
                        path: entry.key,
                        matches: entry.value,
                        onOpen: widget.onOpen,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _FileGroup extends StatelessWidget {
  final String rootPath;
  final String path;
  final List<ProjectSearchMatch> matches;
  final void Function(String path, int line) onOpen;

  const _FileGroup({
    required this.rootPath,
    required this.path,
    required this.matches,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: EdgeInsets.zero,
      initiallyExpanded: true,
      title: Text(
        p.relative(path, from: rootPath),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${matches.length}',
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      children: [
        for (final match in matches)
          InkWell(
            onTap: () => onOpen(match.path, match.line),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 3, 8, 3),
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${match.line}',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      match.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
