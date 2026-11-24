import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';

import '../../services/desktop_prefs_service.dart';
import '../../services/desktop_terminal_service.dart';
import '../../services/toolchain/toolchain_manager.dart';

/// 底部面板内嵌多终端（PTY + xterm）。
///
/// - 顶部为会话页签，可新建 / 切换 / 关闭；
/// - 右侧会话列表展示每个终端的 shell 与运行状态；
/// - AI 在独立会话中执行命令，不会抢走用户正在输入的终端。
class EmbeddedTerminal extends StatefulWidget {
  /// 终端工作目录（通常是项目根目录）
  final String? projectPath;

  /// 是否为当前可见页签：不可见时不启动 PTY，避免后台常驻 shell
  final bool active;

  const EmbeddedTerminal({super.key, this.projectPath, this.active = true});

  @override
  State<EmbeddedTerminal> createState() => _EmbeddedTerminalState();
}

class _EmbeddedTerminalState extends State<EmbeddedTerminal> {
  DesktopTerminalService get _service => DesktopTerminalService.instance;

  bool _showSessionRail = true;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted());
    }
  }

  @override
  void didUpdateWidget(covariant EmbeddedTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) return;
    if (oldWidget.projectPath != widget.projectPath) {
      // 切换项目：结束旧会话，在新目录重开
      if (_restarting) return;
      _restarting = true;
      unawaited(
        _service.closeAll().then((_) {
          _restarting = false;
          _ensureStarted();
        }),
      );
      return;
    }
    if (!oldWidget.active) _ensureStarted();
  }

  Map<String, String> _environment() => ToolchainManager.instance
      .environment(projectPath: widget.projectPath)
      .build();

  void _ensureStarted() {
    if (!mounted) return;
    if (_service.hasSessions) return;
    unawaited(
      _service.createSession(
        workingDirectory: widget.projectPath,
        environment: _environment(),
      ),
    );
  }

  Future<void> _newTerminal() async {
    final session = await _service.createSession(
      workingDirectory: widget.projectPath,
      environment: _environment(),
    );
    _service.setActive(session.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor =
        isDark ? const Color(0xFF3C3C3C) : const Color(0xFFD4D4D4);
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final sessions = _service.sessions;
        final active = _service.activeSession;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 30,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF2D2D2D)
                    : const Color(0xFFECECEC),
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  Icon(
                    Icons.terminal,
                    size: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: _buildTabs(theme, isDark)),
                  _toolbarButton(
                    icon: Icons.add,
                    tooltip: '新建终端',
                    onTap: _newTerminal,
                  ),
                  _toolbarButton(
                    icon: Icons.cleaning_services_outlined,
                    tooltip: '清屏',
                    onTap: _service.clear,
                  ),
                  _toolbarButton(
                    icon: Icons.delete_outline,
                    tooltip: '结束当前终端',
                    onTap: () async {
                      final id = _service.activeSessionId;
                      if (id == null) return;
                      await _service.stopSession(id);
                    },
                  ),
                  _toolbarButton(
                    icon: _showSessionRail
                        ? Icons.view_sidebar
                        : Icons.view_sidebar_outlined,
                    tooltip: _showSessionRail ? '隐藏会话列表' : '显示会话列表',
                    onTap: () =>
                        setState(() => _showSessionRail = !_showSessionRail),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildTerminalView(theme, isDark, active)),
                  if (_showSessionRail && sessions.length > 1)
                    _buildSessionRail(theme, isDark, sessions),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTabs(ThemeData theme, bool isDark) {
    final sessions = _service.sessions;
    if (sessions.isEmpty) {
      return Text(
        '正在启动终端…',
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      );
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: sessions.length,
      separatorBuilder: (_, __) => const SizedBox(width: 2),
      itemBuilder: (context, index) {
        final session = sessions[index];
        final selected = session.id == _service.activeSessionId;
        final running = session.running;
        return InkWell(
          onTap: () => _service.setActive(session.id),
          child: Container(
            padding: const EdgeInsets.only(left: 8, right: 2),
            decoration: BoxDecoration(
              color: selected
                  ? (isDark
                      ? const Color(0xFF1E1E1E)
                      : Colors.white)
                  : Colors.transparent,
              border: Border(
                top: BorderSide(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  running ? Icons.circle : Icons.warning_amber_rounded,
                  size: running ? 6 : 11,
                  color: running
                      ? (isDark ? Colors.greenAccent : Colors.green)
                      : Colors.orange,
                ),
                const SizedBox(width: 5),
                Text(
                  session.title,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                InkWell(
                  onTap: () => _service.closeSession(session.id),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTerminalView(
    ThemeData theme,
    bool isDark,
    TerminalSession? active,
  ) {
    if (active == null) {
      // 未启动时不要用无限转圈：进度圈会持续驱动帧，造成整窗重绘与输入迟滞
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text('终端未启动', style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    return TerminalView(
      active.terminal,
      key: ValueKey(active.id),
      autofocus: true,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      theme: isDark ? TerminalThemes.defaultTheme : _lightTheme,
      textStyle: TerminalStyle(
        fontSize: DesktopPrefsService.instance.terminalFontSize,
        fontFamily: 'monospace',
      ),
    );
  }

  Widget _buildSessionRail(
    ThemeData theme,
    bool isDark,
    List<TerminalSession> sessions,
  ) {
    return Container(
      width: 148,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3),
        border: Border(
          left: BorderSide(
            color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFD4D4D4),
          ),
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          final selected = session.id == _service.activeSessionId;
          final shellName = p.basename(session.shell);
          return InkWell(
            onTap: () => _service.setActive(session.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              child: Row(
                children: [
                  Icon(
                    session.running
                        ? Icons.terminal
                        : Icons.warning_amber_rounded,
                    size: 12,
                    color: session.running
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          session.running
                              ? '$shellName · 运行中'
                              : '$shellName · 已退出',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          child: Icon(icon, size: 14),
        ),
      ),
    );
  }

  static const TerminalTheme _lightTheme = TerminalTheme(
    cursor: Color(0xFF333333),
    selection: Color(0x40264F78),
    foreground: Color(0xFF333333),
    background: Color(0xFFFDFDFD),
    black: Color(0xFF000000),
    red: Color(0xFFC91B00),
    green: Color(0xFF00A600),
    yellow: Color(0xFFB8860B),
    blue: Color(0xFF0037DA),
    magenta: Color(0xFF8B008B),
    cyan: Color(0xFF008B8B),
    white: Color(0xFFBFBFBF),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFE50000),
    brightGreen: Color(0xFF00D900),
    brightYellow: Color(0xFFE5A000),
    brightBlue: Color(0xFF3B78FF),
    brightMagenta: Color(0xFFB200B2),
    brightCyan: Color(0xFF00B7B7),
    brightWhite: Color(0xFF000000),
    searchHitBackground: Color(0xFFFFF2A8),
    searchHitBackgroundCurrent: Color(0xFFFFC800),
    searchHitForeground: Color(0xFF000000),
  );
}
