import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';

class QuickOpenResult {
  final String path;
  final int? line;
  final int? column;

  const QuickOpenResult(this.path, {this.line, this.column});
}

/// 快速打开文件（Ctrl/Cmd+P）：输入文件名模糊匹配，支持 `:行号`。
Future<QuickOpenResult?> showQuickOpen({
  required BuildContext context,
  required String rootPath,
  required List<String> files,
}) {
  return showDialog<QuickOpenResult>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => _QuickOpenDialog(rootPath: rootPath, files: files),
  );
}

class _QuickOpenDialog extends StatefulWidget {
  final String rootPath;
  final List<String> files;

  const _QuickOpenDialog({required this.rootPath, required this.files});

  @override
  State<_QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends State<_QuickOpenDialog> {
  final TextEditingController _controller = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ({String query, int? line}) _parseQuery() {
    final raw = _controller.text.trim();
    final match = RegExp(r'^(.*?):(\d+)$').firstMatch(raw);
    if (match != null) {
      return (
        query: match.group(1)!.trim(),
        line: int.tryParse(match.group(2)!),
      );
    }
    return (query: raw, line: null);
  }

  List<String> get _filtered {
    final parsed = _parseQuery();
    final query = parsed.query.toLowerCase();
    final scored = <({String path, int score})>[];
    for (final path in widget.files) {
      final relative = p.relative(path, from: widget.rootPath);
      final score = _score(relative.toLowerCase(), query);
      if (score > 0) scored.add((path: path, score: score));
    }
    scored.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      return a.path.length.compareTo(b.path.length);
    });
    return scored.take(80).map((e) => e.path).toList();
  }

  /// 简单模糊匹配：连续命中 > 单词首字母命中 > 子序列命中。
  int _score(String target, String query) {
    if (query.isEmpty) return 1000;
    if (target.endsWith(query)) return 1000;
    final basename = p.basename(target);
    if (basename.startsWith(query)) return 900;
    if (basename.contains(query)) return 800;
    if (target.contains(query)) return 700;
    var ti = 0;
    var consecutive = 0;
    var best = 0;
    for (var qi = 0; qi < query.length; qi++) {
      final ch = query[qi];
      var found = false;
      while (ti < target.length) {
        if (target[ti] == ch) {
          consecutive++;
          best = best > consecutive ? best : consecutive;
          ti++;
          found = true;
          break;
        }
        consecutive = 0;
        ti++;
      }
      if (!found) return 0;
    }
    return 300 + best * 10;
  }

  void _choose(String path) {
    final parsed = _parseQuery();
    Navigator.of(context).pop(QuickOpenResult(path, line: parsed.line));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final items = _filtered;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && items.isNotEmpty) {
      setState(() => _selected = (_selected + 1) % items.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && items.isNotEmpty) {
      setState(() => _selected = (_selected - 1 + items.length) % items.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && items.isNotEmpty) {
      _choose(items[_selected.clamp(0, items.length - 1)]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _filtered;
    if (_selected >= items.length) {
      _selected = items.isEmpty ? 0 : items.length - 1;
    }
    return Align(
      alignment: const Alignment(0, -0.72),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 640,
          constraints: const BoxConstraints(maxHeight: 480),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.dividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Focus(
                  onKeyEvent: _handleKey,
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon: const Icon(
                        Icons.description_outlined,
                        size: 20,
                      ),
                      hintText: t('desktop.quickOpen.placeholder'),
                    ),
                    onChanged: (_) => setState(() => _selected = 0),
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(t('desktop.search.noResults')),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final path = items[index];
                          final relative = p.relative(
                            path,
                            from: widget.rootPath,
                          );
                          final selected = index == _selected;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            leading: const Icon(
                              Icons.insert_drive_file_outlined,
                              size: 18,
                            ),
                            title: Text(
                              p.basename(relative),
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              p.dirname(relative) == '.'
                                  ? ''
                                  : p.dirname(relative),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => _choose(path),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
