import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/crash_analyzer.dart';
import '../../services/crash_log_service.dart';
import '../../services/desktop_platform.dart';
import '../../widgets/desktop/desktop_title_bar.dart';

/// SLIPE 异常窗口
///
/// 编辑器进程异常退出时由 Hub 打开：展示系统 / 版本 / 时间 / 退出码与
/// 关键错误信息，自动分析可能原因，并支持一键导出完整错误日志。
class CrashReportScreen extends StatefulWidget {
  const CrashReportScreen({super.key, required this.report});

  final EditorCrashReport report;

  @override
  State<CrashReportScreen> createState() => _CrashReportScreenState();
}

class _CrashReportScreenState extends State<CrashReportScreen> {
  late final CrashAnalysis _analysis;

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _analysis = analyzeEditorCrash(
      exitCode: widget.report.exitCode,
      logLines: widget.report.logLines,
    );
  }

  Future<void> _exportLog() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final suffix = _timeStamp(widget.report.endedAt);
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: '导出错误日志',
        fileName: 'slipe-crash-$suffix.txt',
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        _toast('无法打开保存对话框：$e');
      }
      return;
    }
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _exporting = false);
      return;
    }
    try {
      if (!path.toLowerCase().endsWith('.txt')) path = '$path.txt';
      await File(path).writeAsString(
        buildCrashReportText(widget.report, _analysis),
        flush: true,
      );
      // 附带原始日志，便于他人排查
      final rawPath = '${path.substring(0, path.length - 4)}.log';
      final raw = await CrashLogService.readText(widget.report.logPath);
      if (raw.isNotEmpty) {
        await File(rawPath).writeAsString(raw, flush: true);
      }
      if (!mounted) return;
      _toast(
        '已导出：$path',
        action: '在文件夹中显示',
        onAction: () {
          DesktopPlatform.revealInFileManager(path!);
        },
      );
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _revealLogFolder() {
    final logPath = widget.report.logPath;
    if (logPath.isEmpty) {
      _toast('未找到日志文件');
      return;
    }
    DesktopPlatform.revealInFileManager(logPath);
  }

  void _toast(String message, {String? action, VoidCallback? onAction}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = Column(
      children: [
        if (DesktopPlatform.isDesktop)
          DesktopTitleBar(
            brand: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Color(0xFFE37318),
              ),
            ),
            menus: const [],
            title: 'SLIPE 异常报告',
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeadline(isDark),
                    const SizedBox(height: 16),
                    _buildExportNotice(isDark),
                    const SizedBox(height: 16),
                    _Section(
                      title: '诊断信息',
                      isDark: isDark,
                      child: Column(
                        children: [
                          _InfoRow(
                            label: '时间',
                            value: _formatTime(widget.report.endedAt),
                          ),
                          _InfoRow(label: '系统', value: widget.report.osLabel),
                          _InfoRow(
                            label: '编辑器版本',
                            value: widget.report.editorVersion,
                          ),
                          _InfoRow(
                            label: 'Hub 版本',
                            value: widget.report.hubVersion,
                          ),
                          _InfoRow(
                            label: '退出码',
                            value: widget.report.exitLabel,
                          ),
                          _InfoRow(
                            label: '运行时长',
                            value: _formatDuration(widget.report.duration),
                          ),
                          _InfoRow(
                            label: '项目',
                            value: widget.report.projectName,
                            selectable: false,
                          ),
                          _InfoRow(
                            label: '项目路径',
                            value: widget.report.projectPath,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: '关键错误信息',
                      isDark: isDark,
                      child: SelectableText(
                        widget.report.keyError,
                        style: TextStyle(
                          fontFamily: DesktopPlatform.osMonospaceFont,
                          fontSize: 12,
                          height: 1.6,
                          color: isDark
                              ? const Color(0xFFFF9A9A)
                              : const Color(0xFFC0392B),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: '自动分析',
                      isDark: isDark,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _analysis.headline,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          for (final finding in _analysis.findings)
                            _Bullet(text: finding, isDark: isDark),
                          if (_analysis.suggestions.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              '建议',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 6),
                            for (final suggestion in _analysis.suggestions)
                              _Bullet(
                                text: suggestion,
                                isDark: isDark,
                                icon: Icons.lightbulb_outline,
                              ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: '日志预览（最近 ${widget.report.logLines.length} 行）',
                      isDark: isDark,
                      child: Container(
                        height: 220,
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF141417)
                              : const Color(0xFFF7F7F9),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isDark
                                ? Colors.white12
                                : const Color(0xFFE4E6EB),
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            widget.report.logLines.isEmpty
                                ? '（未捕获到日志输出）'
                                : widget.report.logLines.join('\n'),
                            style: TextStyle(
                              fontFamily: DesktopPlatform.osMonospaceFont,
                              fontSize: 11,
                              height: 1.5,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.black.withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 操作区放在滚动内容末尾：小窗口下也能滚动到
                    _buildActions(isDark),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: content,
    );
  }

  Widget _buildHeadline(bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFE37318).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.report_gmailerrorred,
            color: Color(0xFFE37318),
            size: 26,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _analysis.headline,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '项目「${widget.report.projectName}」的编辑器进程已退出，'
                'Hub 仍可继续使用。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 主操作固定在首屏可见位置（内容较长时无需滚动即可导出）
        FilledButton.icon(
          onPressed: _exporting ? null : _exportLog,
          icon: _exporting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined, size: 18),
          label: Text(_exporting ? '导出中…' : '导出错误日志'),
        ),
      ],
    );
  }

  Widget _buildExportNotice(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE37318).withValues(alpha: isDark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFFE37318).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: Color(0xFFE37318)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '如果你需要寻求他人帮助，请点击「导出错误日志」并把日志文件发送给对方，'
              '而不是截图这个窗口——截图会丢失排查所需的关键信息。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? const Color(0xFFFFC48A)
                    : const Color(0xFF9A4A00),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white12 : const Color(0xFFE4E6EB),
          ),
        ),
      ),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: _exporting ? null : _exportLog,
            icon: _exporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 18),
            label: Text(_exporting ? '导出中…' : '导出错误日志'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _revealLogFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('打开日志目录'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('返回 Hub'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.isDark,
    required this.child,
  });

  final String title;
  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232327) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE4E6EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = true,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = TextStyle(
      fontSize: 12,
      height: 1.6,
      color: isDark ? Colors.white70 : Colors.black87,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.text,
    required this.isDark,
    this.icon = Icons.circle,
  });

  final String text;
  final bool isDark;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              icon,
              size: icon == Icons.circle ? 6 : 14,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

String _formatDuration(Duration duration) {
  if (duration.inSeconds < 60) return '${duration.inSeconds} 秒';
  return '${duration.inMinutes} 分 ${duration.inSeconds % 60} 秒';
}

String _timeStamp(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}-'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
}
