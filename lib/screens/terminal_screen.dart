import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// 底部弹出式终端
///
/// 只要有 Termux 即可使用，无需 proot 容器。
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
    'termux-info',
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

  Future<void> _openTermuxSite() async {
    final uri = Uri.parse('https://f-droid.org/packages/com.termux/');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('terminal.openFailed', {'url': uri.toString()})),
        ),
      );
    }
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
            if (!terminal.isReady && terminal.supported)
              _buildSetupBanner(terminal),
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

  /// Termux 未就绪时的引导面板
  ///
  /// - 未安装 Termux：给下载入口
  /// - 已安装但未授权 / allow-external-apps 未开启：给申请权限按钮
  ///   与 4 条需要在 Termux 内执行的配置命令（点按复制）
  Widget _buildSetupBanner(TerminalProvider terminal) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      color: Colors.orange.withValues(alpha: 0.15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  terminal.needsTermux
                      ? t('terminal.needsTermux')
                      : (terminal.error ?? t('terminal.notReady')),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: terminal.starting ? null : terminal.ensureStarted,
                child: Text(t('common.retry')),
              ),
            ],
          ),
          if (terminal.needsTermux)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _openTermuxSite,
                child: Text(t('terminal.install')),
              ),
            )
          else if (terminal.detected) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!terminal.permissionGranted)
                  FilledButton.tonalIcon(
                    onPressed: terminal.requestTermuxPermission,
                    icon: const Icon(Icons.security, size: 16),
                    label: const Text(
                      '申请 Termux 权限',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                TextButton.icon(
                  onPressed: terminal.openTermux,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text(
                    '打开 Termux',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (!terminal.allowExternalAppsOk ||
                !terminal.permissionGranted) ...[
              const SizedBox(height: 6),
              Text(
                '请在 Termux 中依次执行以下命令（点按可复制）：',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.orange.shade200
                      : Colors.orange.shade900,
                ),
              ),
              const SizedBox(height: 4),
              ...TerminalProvider.termuxSetupCommands.map(_buildCommandRow),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCommandRow(String command) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: command));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制命令'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1B1B1D) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark ? Colors.white12 : Colors.black12,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                command,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.copy,
              size: 14,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ],
        ),
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
