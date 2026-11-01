import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/project_provider.dart';
import '../providers/terminal_provider.dart';
import '../widgets/log_console.dart';
import '../widgets/symbol_keypad.dart';

/// 从底部弹出终端面板
Future<void> showTerminalSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => const FractionallySizedBox(
      heightFactor: 0.86,
      child: TerminalSheet(),
    ),
  );
}

/// 底部弹出式终端（仅桌面端可用，使用系统 shell）
class TerminalSheet extends StatefulWidget {
  const TerminalSheet({super.key});

  @override
  State<TerminalSheet> createState() => _TerminalSheetState();
}

class _TerminalSheetState extends State<TerminalSheet> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final List<String> _history = [];
  int _historyIndex = -1;

  static const List<String> _quickCommands = [
    'pwd',
    'ls -la',
    'cd ..',
    'git status',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final terminal = context.read<TerminalProvider>();
      terminal.setProjectDir(context.read<ProjectProvider>().projectPath);
      terminal.ensureStarted();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _insertSymbol(String symbol) {
    final value = _inputController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, symbol);
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + symbol.length),
    );
    _inputFocus.requestFocus();
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _inputController.text).trim();
    if (text.isEmpty) return;

    final terminal = context.read<TerminalProvider>();
    if (terminal.busy) return;

    if (override == null) {
      _history.add(text);
      _historyIndex = -1;
      _inputController.clear();
    }

    _inputFocus.requestFocus();
    await terminal.runCommand(text);
  }

  void _historyBack() {
    if (_history.isEmpty) return;
    if (_historyIndex < 0) {
      _historyIndex = _history.length - 1;
    } else if (_historyIndex > 0) {
      _historyIndex--;
    }
    final text = _history[_historyIndex];
    _inputController.text = text;
    _inputController.selection =
        TextSelection.fromPosition(TextPosition(offset: text.length));
  }

  @override
  Widget build(BuildContext context) {
    final terminal = context.watch<TerminalProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Material(
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            // 拖动条
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _buildHeader(terminal, isDark),
            const Divider(height: 1),
            if (!terminal.supported) _buildUnsupportedBanner(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: LogConsole(
                  lines: terminal.lines,
                  emptyText: terminal.isReady
                      ? t('terminal.emptyHint')
                      : t('terminal.checking'),
                ),
              ),
            ),

            // 快捷命令
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                itemCount: _quickCommands.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final command = _quickCommands[index];
                  return ActionChip(
                    label: Text(
                      command,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: terminal.busy ? null : () => _send(command),
                  );
                },
              ),
            ),

            // 符号小键盘
            SymbolKeypad(
              isDark: isDark,
              onInsert: _insertSymbol,
            ),

            // 输入区
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.history, size: 20),
                      tooltip: t('terminal.history'),
                      onPressed: _historyBack,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        focusNode: _inputFocus,
                        enabled: !terminal.busy,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          prefixText: '\$ ',
                          prefixStyle: const TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.grey,
                          ),
                          hintText: t('terminal.inputHint'),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filled(
                      icon: const Icon(Icons.send, size: 18),
                      tooltip: t('terminal.execute'),
                      onPressed: terminal.busy ? null : () => _send(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down),
                      tooltip: t('terminal.collapse'),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(TerminalProvider terminal, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Icon(
            terminal.isReady ? Icons.terminal : Icons.terminal_outlined,
            size: 16,
            color: terminal.isReady ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          const Text(
            'Terminal',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              terminal.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          if (terminal.lastExitCode != null)
            Text(
              'exit ${terminal.lastExitCode}',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: terminal.lastExitCode == 0
                    ? Colors.green
                    : Colors.redAccent,
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.restart_alt, size: 18),
            tooltip: t('terminal.restart'),
            onPressed: terminal.busy ? null : terminal.restart,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.clear_all, size: 18),
            tooltip: t('terminal.clear'),
            onPressed: terminal.clear,
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: Colors.red.withValues(alpha: 0.1),
      child: Text(
        t('terminal.unsupported'),
        style: const TextStyle(fontSize: 12, color: Colors.redAccent),
      ),
    );
  }
}
