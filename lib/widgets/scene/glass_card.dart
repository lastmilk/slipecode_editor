import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scene_palette.dart';
import 'scene_tokens.dart';

/// 玻璃拟态卡片：整卡可点击、hover 光晕与微缩放、键盘可聚焦。
///
/// 卡片在受约束的父级（如 Bento 网格的 Expanded）中会自动铺满。
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.accent,
    this.radius = SceneTokens.radiusMedium,
    this.padding = const EdgeInsets.all(24),
    this.glow = true,
    this.semanticLabel,
    this.enableHoverScale = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool glow;
  final String? semanticLabel;
  final bool enableHoverScale;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _active => _hovered || _focused;

  void _handleTap() => widget.onTap?.call();

  @override
  Widget build(BuildContext context) {
    // 跟随编辑器明暗主题取色。
    final palette = ScenePalette.of(context);
    final scale = _pressed
        ? 0.99
        : (_active && widget.enableHoverScale ? 1.02 : 1.0);

    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: true,
        mouseCursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _handleTap();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (value) {
          if (_hovered == value) return;
          setState(() => _hovered = value);
        },
        onShowFocusHighlight: (value) {
          if (_focused == value) return;
          setState(() => _focused = value);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = true),
          onTapUp: widget.onTap == null
              ? null
              : (_) => setState(() => _pressed = false),
          onTapCancel: widget.onTap == null
              ? null
              : () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: scale,
            duration: SceneTokens.durationFast,
            curve: SceneTokens.curve,
            child: AnimatedContainer(
              duration: SceneTokens.durationFast,
              curve: SceneTokens.curve,
              decoration: palette.glassDecoration(
                accent: widget.accent,
                radius: widget.radius,
                glow: widget.glow && _active,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.radius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Padding(
                    padding: widget.padding,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
