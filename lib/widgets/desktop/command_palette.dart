import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/command_registry.dart';

/// 命令面板（Ctrl/Cmd+Shift+P）。
Future<void> showCommandPalette(
  BuildContext context,
  List<DesktopCommand> commands,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => _CommandPaletteDialog(commands: commands),
  );
}

class _CommandPaletteDialog extends StatefulWidget {
  final List<DesktopCommand> commands;

  const _CommandPaletteDialog({required this.commands});

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<DesktopCommand> get _filtered {
    final query = _controller.text.trim().toLowerCase();
    final enabled = widget.commands.where((c) => c.enabled).toList();
    if (query.isEmpty) return enabled;
    return enabled.where((c) {
      final haystack = '${c.label} ${c.id} ${c.description ?? ''}'
          .toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  void _run(DesktopCommand command) {
    Navigator.of(context).pop();
    command.run();
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
      _run(items[_selected.clamp(0, items.length - 1)]);
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
          width: 620,
          constraints: const BoxConstraints(maxHeight: 460),
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
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: t('desktop.action.commandPalette'),
                    ),
                    onChanged: (_) => setState(() => _selected = 0),
                    onSubmitted: (_) {
                      if (items.isNotEmpty) _run(items[_selected]);
                    },
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
                          final command = items[index];
                          final selected = index == _selected;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            leading: Icon(_iconFor(command.id), size: 18),
                            title: Text(
                              command.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: command.description == null
                                ? null
                                : Text(
                                    command.description!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                            trailing: command.shortcutLabel.isEmpty
                                ? null
                                : Text(
                                    command.shortcutLabel,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                            onTap: () => _run(command),
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

  IconData _iconFor(String id) {
    if (id.contains('save')) return Icons.save_outlined;
    if (id.contains('build')) return Icons.build_outlined;
    if (id.contains('run')) return Icons.play_arrow;
    if (id.contains('terminal')) return Icons.terminal;
    if (id.contains('format')) return Icons.format_align_left;
    if (id.contains('rename')) return Icons.drive_file_rename_outline;
    if (id.contains('definition')) return Icons.my_location;
    if (id.contains('reference')) return Icons.find_in_page;
    if (id.contains('close')) return Icons.close;
    if (id.contains('panel')) return Icons.view_agenda_outlined;
    if (id.contains('sidebar')) return Icons.view_sidebar_outlined;
    return Icons.play_circle_outline;
  }
}
