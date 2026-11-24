import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/scene.dart';
import '../../widgets/scene/scene_backdrop.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';

/// 移动端断点：小于该宽度时收成单栏，左右面板改为底部弹层。
const double _kMobileBreakpoint = 900;

/// 场景强调色在浅色底上的文字色：压暗一点保证对比度。
Color _accentTextColor(ScenePalette palette, Color accent) {
  if (palette.isDark) return accent;
  return Color.lerp(accent, Colors.black, 0.3) ?? accent;
}

/// 强调色按钮上的前景色：按亮度自动选黑或白。
Color _onAccentColor(Color accent) {
  return accent.computeLuminance() > 0.55 ? Colors.black : Colors.white;
}

/// 场景工作台统一外壳。
///
/// 结构：主题渐变背景 + 场景动态符号 + 顶栏 + 三栏布局
/// （左侧面板 280 / 主区 / 右侧面板 340）。
/// 宽度 < 900 时切换为单栏：左右面板通过顶栏按钮以底部弹层打开。
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.symbol,
    required this.body,
    this.leftPanel,
    this.rightPanel,
    this.actions = const [],
    this.statusLabel,
    this.onBack,
  });

  /// 工作台标题，如 `VibeVideo`。
  final String title;

  /// 副标题，通常为「细分元素 · 项目类型」。
  final String subtitle;

  /// 场景强调色。
  final Color accent;

  /// 场景背景符号类型。
  final SceneSymbolKind symbol;

  /// 主内容区。
  final Widget body;

  /// 左侧面板（素材 / 模板 / 记忆库等）。
  final Widget? leftPanel;

  /// 右侧面板（AI 指令 / 策略说明等）。
  final Widget? rightPanel;

  /// 顶栏右侧操作按钮。
  final List<Widget> actions;

  /// 顶栏状态文案，如「已保存」。
  final String? statusLabel;

  /// 返回回调；为空时默认 `Navigator.maybePop`。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final windowWidth = MediaQuery.sizeOf(context).width;
    final isMobile = windowWidth < _kMobileBreakpoint;

    // 桌面端沿用原有阈值；移动端不再渲染左右栏。
    final showLeft = !isMobile && leftPanel != null && windowWidth >= 1000;
    final showRight = !isMobile && rightPanel != null && windowWidth >= 1180;

    return Scaffold(
      backgroundColor: palette.bgTop,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.backgroundGradient),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: SceneBackdrop(
                  symbol: symbol,
                  accent: accent,
                  opacity: 0.6,
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: isMobile
                    ? const EdgeInsets.fromLTRB(12, 8, 12, 12)
                    : const EdgeInsets.fromLTRB(24, 14, 24, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: isMobile ? 56 : 64,
                      child: _buildHeader(context, palette, isMobile),
                    ),
                    SizedBox(height: isMobile ? 10 : 14),
                    Expanded(
                      child: isMobile
                          ? body
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (showLeft) ...[
                                  SizedBox(width: 280, child: leftPanel),
                                  const SizedBox(width: SceneTokens.gap),
                                ],
                                Expanded(child: body),
                                if (showRight) ...[
                                  const SizedBox(width: SceneTokens.gap),
                                  SizedBox(width: 340, child: rightPanel),
                                ],
                              ],
                            ),
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

  Widget _buildHeader(
    BuildContext context,
    ScenePalette palette,
    bool isMobile,
  ) {
    final width = MediaQuery.sizeOf(context).width;
    final showSubtitle = !isMobile || width >= 600;
    // 极窄屏省略状态与角标，给标题留出空间。
    final compact = isMobile && width < 600;

    final titleColumn = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SceneTokens.sceneTitle(22, color: palette.textPrimary),
        ),
        if (showSubtitle) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SceneTokens.sceneBody(12.5, color: palette.textTertiary),
          ),
        ],
      ],
    );

    return Row(
      children: [
        _BackButton(
          palette: palette,
          accent: accent,
          onTap: onBack ?? () => Navigator.maybePop(context),
        ),
        SizedBox(width: isMobile ? 8 : 12),
        if (isMobile)
          Expanded(child: titleColumn)
        else
          Flexible(child: titleColumn),
        SizedBox(width: isMobile ? 4 : 12),
        // 移动端：面板入口（仅当对应面板存在时显示）。
        if (isMobile && leftPanel != null)
          _PanelIconButton(
            icon: Icons.view_sidebar_rounded,
            tooltip: '面板',
            accent: accent,
            onTap: () =>
                _openPanelSheet(context, title: '面板', child: leftPanel!),
          ),
        if (isMobile && leftPanel != null && rightPanel != null)
          const SizedBox(width: 6),
        if (isMobile && rightPanel != null)
          _PanelIconButton(
            icon: Icons.auto_awesome_rounded,
            tooltip: 'AI',
            accent: accent,
            onTap: () =>
                _openPanelSheet(context, title: 'AI 指令', child: rightPanel!),
          ),
        if (actions.isNotEmpty && !compact) ...[
          const SizedBox(width: 10),
          if (isMobile)
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _buildActions(),
              ),
            )
          else
            _buildActions(mainAxisSize: MainAxisSize.min),
        ],
        if (statusLabel != null && !compact) ...[
          const SizedBox(width: 10),
          _StatusChip(label: statusLabel!, accent: accent, palette: palette),
        ],
        if (!compact) ...[
          const SizedBox(width: 10),
          _ConceptBadge(accent: accent, palette: palette),
        ],
      ],
    );
  }

  Widget _buildActions({MainAxisSize mainAxisSize = MainAxisSize.min}) {
    return Row(
      mainAxisSize: mainAxisSize,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          actions[i],
        ],
      ],
    );
  }

  /// 移动端把面板放进底部弹层，高度为屏幕的 72%。
  void _openPanelSheet(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    final palette = ScenePalette.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (sheetContext) {
        return SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.72,
          child: Material(
            color: palette.bgTop,
            clipBehavior: Clip.antiAlias,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部拖拽指示条。
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 8, bottom: 2),
                      decoration: BoxDecoration(
                        color: palette.divider,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SceneTokens.sceneBody(
                              14,
                              color: palette.textPrimary,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({
    required this.palette,
    required this.accent,
    required this.onTap,
  });

  final ScenePalette palette;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '返回',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: accent.withValues(alpha: 0.08),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.glassFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.glassBorder),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 18,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端顶栏的面板 / AI 入口。
class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({
    required this.icon,
    required this.tooltip,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: accent.withValues(alpha: 0.08),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.glassFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.glassBorder),
                ),
                child: Icon(icon, size: 18, color: palette.textPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.accent,
    required this.palette,
  });

  final String label;
  final Color accent;
  final ScenePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: palette.glassFillStrong,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: SceneTokens.sceneCaption(11, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ConceptBadge extends StatelessWidget {
  const _ConceptBadge({required this.accent, required this.palette});

  final Color accent;
  final ScenePalette palette;

  @override
  Widget build(BuildContext context) {
    final textColor = _accentTextColor(palette, accent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: palette.isDark ? 0.12 : 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        '概念版',
        style: SceneTokens.sceneCaption(
          11,
          color: textColor,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 工作台内的小节容器：小标题 + 内容，带玻璃质感。
class WorkspaceSection extends StatelessWidget {
  const WorkspaceSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.accent,
    this.padding = const EdgeInsets.all(16),
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final Color? accent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      padding: padding,
      decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (accent != null) ...[
                Container(
                  width: 3,
                  height: 13,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneCaption(
                    12,
                    color: palette.textSecondary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// AI 指令面板（概念版：本地模拟回复，不调用真实模型）。
class WorkspaceAiPanel extends StatefulWidget {
  const WorkspaceAiPanel({
    super.key,
    required this.accentLabel,
    required this.accent,
    required this.cannedResponses,
    required this.onSend,
    this.hint = '描述你想让 AI 做什么…',
    this.title = 'AI 指令',
    this.onInsert,
  });

  final String accentLabel;
  final Color accent;
  final List<String> cannedResponses;

  /// 发送指令回调（用于工作台记录或联动）。
  final Future<void> Function(String text) onSend;

  final String hint;
  final String title;

  /// 提供后，AI 回复下方显示「插入」按钮。
  final ValueChanged<String>? onInsert;

  @override
  State<WorkspaceAiPanel> createState() => _WorkspaceAiPanelState();
}

class _AiMessage {
  _AiMessage({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

class _WorkspaceAiPanelState extends State<WorkspaceAiPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_AiMessage> _messages = [];

  Timer? _replyTimer;
  bool _sending = false;
  int _replyCursor = 0;

  @override
  void dispose() {
    _replyTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() {
      _messages.add(_AiMessage(fromUser: true, text: text));
      _sending = true;
    });
    _scrollToBottom();

    try {
      await widget.onSend(text);
    } catch (e) {
      debugPrint('AI 指令回调失败：$e');
    }
    if (!mounted) return;

    final reply = widget.cannedResponses.isEmpty
        ? '（概念版）已记录你的指令，接入模型后会返回真实结果。'
        : widget.cannedResponses[_replyCursor++ %
              widget.cannedResponses.length];

    _replyTimer?.cancel();
    _replyTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _messages.add(_AiMessage(fromUser: false, text: reply));
        _sending = false;
      });
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < _kMobileBreakpoint;
    final accentText = _accentTextColor(palette, widget.accent);

    final content = Container(
      padding: const EdgeInsets.all(14),
      decoration: palette.glassDecoration(radius: SceneTokens.radiusSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  widget.accentLabel,
                  style: SceneTokens.sceneCaption(
                    10,
                    color: accentText,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    13.5,
                    color: palette.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '输入指令，AI 会返回概念版模拟回复；\n结果可一键插入当前内容。',
                        textAlign: TextAlign.center,
                        style: SceneTokens.sceneCaption(
                          12,
                          color: palette.textTertiary,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    itemCount: _messages.length + (_sending ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      if (index >= _messages.length) {
                        return _TypingBubble(
                          accent: widget.accent,
                          palette: palette,
                        );
                      }
                      return _buildBubble(_messages[index], palette);
                    },
                  ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: palette.inputFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.glassBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 3,
              cursorColor: widget.accent,
              style: SceneTokens.sceneBody(13, color: palette.textPrimary),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: SceneTokens.sceneBody(
                  12.5,
                  color: palette.textTertiary,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                backgroundColor: widget.accent,
                foregroundColor: _onAccentColor(widget.accent),
                disabledBackgroundColor: widget.accent.withValues(alpha: 0.3),
                disabledForegroundColor: palette.textTertiary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text(
                '发送指令',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );

    // 移动端避让软键盘，避免输入框被遮挡。
    if (!isMobile) return content;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: content,
    );
  }

  Widget _buildBubble(_AiMessage message, ScenePalette palette) {
    final mine = message.fromUser;
    final accentText = _accentTextColor(palette, widget.accent);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 270),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: mine
              ? widget.accent.withValues(alpha: palette.isDark ? 0.16 : 0.18)
              : palette.glassFillStrong,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(10),
            topRight: const Radius.circular(10),
            bottomLeft: Radius.circular(mine ? 10 : 3),
            bottomRight: Radius.circular(mine ? 3 : 10),
          ),
          border: Border.all(
            color: mine
                ? widget.accent.withValues(alpha: 0.28)
                : palette.glassBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: SceneTokens.sceneBody(12.5, color: palette.textPrimary),
            ),
            if (!mine) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '概念版',
                    style: SceneTokens.sceneCaption(
                      10,
                      color: accentText,
                      weight: FontWeight.w600,
                    ),
                  ),
                  if (widget.onInsert != null) ...[
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: () => widget.onInsert!(message.text),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.add_rounded,
                              size: 12,
                              color: accentText,
                            ),
                            Text(
                              '插入',
                              style: SceneTokens.sceneCaption(
                                10,
                                color: accentText,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.accent, required this.palette});

  final Color accent;
  final ScenePalette palette;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: palette.glassFillStrong,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '正在生成…',
              style: SceneTokens.sceneCaption(11, color: palette.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
