import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/container_provider.dart';
import '../providers/project_provider.dart';
import '../providers/terminal_provider.dart';
import '../widgets/log_console.dart';
import 'container_setup_screen.dart';

/// 项目命令行终端
///
/// 基于 proot 容器中的常驻 /bin/sh 会话
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final List<String> _history = [];

  static const List<String> _quickCommands = [
    'pwd',
    'ls -la',
    'cat /etc/os-release',
    'flutter --version',
    'dart --version',
    'apk update',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final projectPath = context.read<ProjectProvider>().projectPath;
      final terminal = context.read<TerminalProvider>();
      terminal.setProjectDir(projectPath);

      final container = context.read<ContainerProvider>();
      container.refresh().then((_) {
        if (mounted && container.ready) {
          terminal.ensureStarted();
        }
      });
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _inputController.text).trim();
    if (text.isEmpty) return;

    final terminal = context.read<TerminalProvider>();
    if (terminal.busy) return;

    if (override == null) {
      _history.add(text);
      _inputController.clear();
    }

    _inputFocus.requestFocus();
    await terminal.runCommand(text);
  }

  Future<void> _openSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ContainerSetupScreen()),
    );
    if (!mounted) return;
    final container = context.read<ContainerProvider>();
    final terminal = context.read<TerminalProvider>();
    await container.refresh();
    if (container.ready && !terminal.isReady) {
      await terminal.ensureStarted();
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminal = context.watch<TerminalProvider>();
    final container = context.watch<ContainerProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('终端'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: '重启会话',
            onPressed: terminal.busy ? null : terminal.restart,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空输出',
            onPressed: terminal.clear,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '容器设置',
            onPressed: _openSetup,
          ),
        ],
      ),
      body: Column(
        children: [
          if (!container.ready)
            _SetupBanner(
              isDark: isDark,
              checking: container.checking,
              onSetup: _openSetup,
              onRetry: container.refresh,
            ),

          // 状态条
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: isDark ? const Color(0xFF252526) : const Color(0xFFEDEDED),
            child: Row(
              children: [
                Icon(
                  terminal.isReady ? Icons.terminal : Icons.terminal_outlined,
                  size: 14,
                  color: terminal.isReady ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    terminal.cwd,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                    overflow: TextOverflow.ellipsis,
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
                if (terminal.busy) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),

          // 输出
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: LogConsole(
                lines: terminal.lines,
                emptyText: terminal.isReady
                    ? '输入命令开始操作，例如 ls -la'
                    : '等待容器会话启动...',
              ),
            ),
          ),

          // 快捷命令
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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

          // 输入区
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_history.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.history, size: 20),
                      tooltip: '上一条命令',
                      onPressed: () {
                        _inputController.text = _history.last;
                        _inputController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _inputController.text.length),
                        );
                      },
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
                        hintText: '输入 shell 命令',
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
                    tooltip: '执行',
                    onPressed: terminal.busy ? null : () => _send(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  final bool isDark;
  final bool checking;
  final VoidCallback onSetup;
  final VoidCallback onRetry;

  const _SetupBanner({
    required this.isDark,
    required this.checking,
    required this.onSetup,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const LinearProgressIndicator(minHeight: 3);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: Colors.orange.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'proot 容器未就绪，无法执行命令',
              style: TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('重试'),
          ),
          FilledButton.tonal(
            onPressed: onSetup,
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }
}
