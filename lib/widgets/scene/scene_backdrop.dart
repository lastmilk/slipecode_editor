import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/scene.dart';
import 'scene_palette.dart';

/// 场景专属动态背景符号。
///
/// 使用 CustomPainter 绘制五种低对比度符号，置于内容下层。
/// 页面不可见时由 [TickerMode] 自动暂停动画（AnimationController 会随之静音）。
class SceneBackdrop extends StatefulWidget {
  const SceneBackdrop({
    super.key,
    required this.symbol,
    required this.accent,
    this.seed = 0,
    this.opacity = 1.0,
    this.animate = true,
  });

  final SceneSymbolKind symbol;
  final Color accent;
  final int seed;
  final double opacity;
  final bool animate;

  @override
  State<SceneBackdrop> createState() => _SceneBackdropState();
}

class _SceneBackdropState extends State<SceneBackdrop>
    with SingleTickerProviderStateMixin {
  /// 静态展示时停留的帧位置（0~1）。
  static const double _staticFrame = 0.35;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _durationFor(widget.symbol),
  );

  static Duration _durationFor(SceneSymbolKind symbol) => switch (symbol) {
        SceneSymbolKind.coding => const Duration(seconds: 12),
        SceneSymbolKind.video => const Duration(seconds: 9),
        SceneSymbolKind.auto => const Duration(seconds: 10),
        SceneSymbolKind.text => const Duration(seconds: 14),
        SceneSymbolKind.chat => const Duration(seconds: 11),
      };

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.value = _staticFrame;
    }
  }

  @override
  void didUpdateWidget(covariant SceneBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) {
      _controller.duration = _durationFor(widget.symbol);
    }
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = _staticFrame;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 背景符号颜色跟随主题：深色下用白色，浅色下用黑色。
    final palette = ScenePalette.of(context);
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity.clamp(0.0, 1.0),
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _createPainter(
              widget.symbol,
              _controller,
              widget.accent,
              widget.seed,
              palette.isDark,
            ),
          ),
        ),
      ),
    );
  }
}

CustomPainter _createPainter(
  SceneSymbolKind symbol,
  Animation<double> animation,
  Color accent,
  int seed,
  bool isDark,
) {
  return switch (symbol) {
    SceneSymbolKind.coding => _CodingBackdropPainter(
        animation: animation,
        accent: accent,
        seed: seed,
        isDark: isDark,
      ),
    SceneSymbolKind.video => _VideoBackdropPainter(
        animation: animation,
        accent: accent,
        seed: seed,
        isDark: isDark,
      ),
    SceneSymbolKind.auto => _AutoBackdropPainter(
        animation: animation,
        accent: accent,
        seed: seed,
        isDark: isDark,
      ),
    SceneSymbolKind.text => _TextBackdropPainter(
        animation: animation,
        accent: accent,
        seed: seed,
        isDark: isDark,
      ),
    SceneSymbolKind.chat => _ChatBackdropPainter(
        animation: animation,
        accent: accent,
        seed: seed,
        isDark: isDark,
      ),
  };
}

/// 背景画笔基类：提供伪随机与常用绘制方法。
abstract class _BackdropPainterBase extends CustomPainter {
  _BackdropPainterBase({
    required this.animation,
    required this.accent,
    required this.seed,
    required this.isDark,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color accent;
  final int seed;

  /// 当前是否深色主题；浅色下符号改用深色绘制以保证可见。
  final bool isDark;

  /// 符号基础色：深色主题白色、浅色主题黑色（accent 保持不变）。
  Color get base =>
      isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);

  /// 当前动画进度（0~1）。
  double get t => animation.value;

  /// 稳定伪随机值（0~1），保证同一卡片每帧布局一致。
  double rand(int salt) {
    final v = math.sin((salt + 1) * 12.9898 + (seed + 1) * 78.233) * 43758.5453;
    return v - v.floorToDouble();
  }

  Paint stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color;

  Paint fill(Color color) => Paint()..color = color;

  @override
  bool shouldRepaint(covariant _BackdropPainterBase oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.seed != seed ||
        oldDelegate.isDark != isDark ||
        oldDelegate.animation != animation;
  }
}

// ---------------- VibeCoding：流动代码行 + 线框网格 ----------------

class _CodingBackdropPainter extends _BackdropPainterBase {
  _CodingBackdropPainter({
    required super.animation,
    required super.accent,
    required super.seed,
    required super.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.clipRect(Offset.zero & size);

    // 线框网格
    final step = math.max(26.0, math.min(w, h) / 9);
    final grid = stroke(base.withValues(alpha: 0.035), 1);
    for (var x = 0.0; x < w; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (var y = 0.0; y < h; y += step) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    // 流动代码行
    const rows = 9;
    final lineH = math.max(4.0, h * 0.016);
    for (var i = 0; i < rows; i++) {
      final lineW = w * (0.14 + rand(i * 7 + 1) * 0.42);
      final y = h * (0.05 + i * 0.11) +
          math.sin((t + i * 0.13) * math.pi * 2) * 3;
      final speed = 0.3 + rand(i * 7 + 2) * 0.9;
      final travel = w + lineW;
      final x = (w * rand(i * 7 + 3) + t * travel * speed) % travel - lineW;
      final isAccent = i % 4 == 0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, lineW, lineH),
          Radius.circular(lineH / 2),
        ),
        fill(
          (isAccent ? accent : base)
              .withValues(alpha: isAccent ? 0.10 : 0.05),
        ),
      );
    }

    // 闪烁光标
    for (var i = 0; i < 3; i++) {
      final blink = (math.sin((t * 4 + i * 0.4) * math.pi * 2) + 1) / 2;
      final center = Offset(
        w * (0.2 + rand(i * 5 + 4) * 0.6),
        h * (0.2 + rand(i * 5 + 5) * 0.6),
      );
      canvas.drawCircle(
        center,
        2 + blink * 1.5,
        fill(accent.withValues(alpha: 0.10 + blink * 0.10)),
      );
    }
  }
}

// ---------------- VibeVideo：胶片帧 + 时间轴扫光 ----------------

class _VideoBackdropPainter extends _BackdropPainterBase {
  _VideoBackdropPainter({
    required super.animation,
    required super.accent,
    required super.seed,
    required super.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.clipRect(Offset.zero & size);

    final stripH = math.min(h * 0.46, w * 0.5);
    final top = (h - stripH) / 2;
    final frameW = stripH * 0.78;
    final gapW = math.max(8.0, w * 0.008);
    final unit = frameW + gapW;
    final count = (w / unit).ceil() + 2;
    final offset = -((t * unit * 1.4) % unit);

    for (var i = 0; i <= count; i++) {
      final x = offset + i * unit;
      final rect = Rect.fromLTWH(x, top, frameW, stripH);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
      canvas.drawRRect(
        rrect,
        fill(base.withValues(alpha: i.isEven ? 0.018 : 0.026)),
      );
      canvas.drawRRect(rrect, stroke(base.withValues(alpha: 0.08), 1));
      // 帧内斜线
      final path = Path()
        ..moveTo(rect.left, rect.bottom)
        ..lineTo(rect.right, rect.top);
      canvas.drawPath(path, stroke(accent.withValues(alpha: 0.05), 1));

      // 中央播放三角
      final play = stripH * 0.15;
      final center = rect.center;
      final playPath = Path()
        ..moveTo(center.dx - play * 0.45, center.dy - play * 0.6)
        ..lineTo(center.dx - play * 0.45, center.dy + play * 0.6)
        ..lineTo(center.dx + play * 0.62, center.dy)
        ..close();
      canvas.drawPath(playPath, fill(accent.withValues(alpha: 0.18)));

      // 底部短进度条（长度随帧序号变化）
      final barW = frameW * (0.24 + rand(i * 17 + 5) * 0.34);
      final barH = math.max(2.0, stripH * 0.022);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rect.left + frameW * 0.12,
            rect.bottom - stripH * 0.1,
            barW,
            barH,
          ),
          Radius.circular(barH / 2),
        ),
        fill(base.withValues(alpha: 0.10)),
      );

      // 右上角小圆点
      final dotR = math.max(2.0, stripH * 0.024);
      canvas.drawCircle(
        Offset(rect.right - dotR * 2.4, rect.top + dotR * 2.2),
        dotR,
        fill(accent.withValues(alpha: 0.2)),
      );
    }

    // 胶片齿孔
    final holeH = math.max(3.0, stripH * 0.05);
    for (var i = 0; i <= count; i++) {
      final x = offset + i * unit + frameW * 0.4;
      for (final y in [top - holeH * 2, top + stripH + holeH]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, frameW * 0.2, holeH),
            Radius.circular(holeH / 2),
          ),
          fill(base.withValues(alpha: 0.05)),
        );
      }
    }

    // 时间轴扫光
    final beamX = (t * 1.3 % 1.0) * (w + 240) - 120;
    final beamRect = Rect.fromLTWH(beamX - 120, 0, 240, h);
    canvas.drawRect(
      beamRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            accent.withValues(alpha: 0),
            accent.withValues(alpha: 0.08),
            accent.withValues(alpha: 0),
          ],
        ).createShader(beamRect),
    );

    // 底部时间轴
    final axisY = top + stripH + holeH * 6;
    canvas.drawLine(
      Offset(w * 0.08, axisY),
      Offset(w * 0.92, axisY),
      stroke(base.withValues(alpha: 0.06), 1.5),
    );
    final playX = w * (0.08 + (t % 1.0) * 0.84);
    canvas.drawCircle(
      Offset(playX, axisY),
      3,
      fill(accent.withValues(alpha: 0.35)),
    );
  }
}

// ---------------- Auto：节点连线脉冲 + 时钟刻度环 ----------------

class _AutoBackdropPainter extends _BackdropPainterBase {
  _AutoBackdropPainter({
    required super.animation,
    required super.accent,
    required super.seed,
    required super.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.clipRect(Offset.zero & size);

    final nodes = [
      Offset(w * 0.16, h * 0.30),
      Offset(w * 0.40, h * 0.66),
      Offset(w * 0.64, h * 0.28),
      Offset(w * 0.86, h * 0.62),
    ];

    // 连线
    final linkPaint = stroke(base.withValues(alpha: 0.08), 1.2);
    for (var i = 0; i < nodes.length - 1; i++) {
      canvas.drawLine(nodes[i], nodes[i + 1], linkPaint);
    }

    // 连线上的脉冲
    for (var i = 0; i < nodes.length - 1; i++) {
      final phase = (t * 1.6 + i * 0.25) % 1.0;
      final pos = Offset.lerp(nodes[i], nodes[i + 1], phase)!;
      canvas.drawCircle(pos, 8, fill(accent.withValues(alpha: 0.10)));
      canvas.drawCircle(pos, 3, fill(accent.withValues(alpha: 0.42)));
    }

    // 节点
    for (var i = 0; i < nodes.length; i++) {
      canvas.drawCircle(
        nodes[i],
        16,
        fill(base.withValues(alpha: 0.035)),
      );
      canvas.drawCircle(
        nodes[i],
        16,
        stroke(base.withValues(alpha: 0.08), 1),
      );
      canvas.drawCircle(nodes[i], 4, fill(accent.withValues(alpha: 0.25)));
    }

    // 时钟刻度环
    final center = Offset(w * 0.82, h * 0.22);
    final radius = math.min(w, h) * 0.13;
    canvas.drawCircle(
      center,
      radius,
      stroke(base.withValues(alpha: 0.06), 1),
    );
    for (var k = 0; k < 12; k++) {
      final angle = k / 12 * math.pi * 2;
      final inner = radius * 0.86;
      final outer = radius * 0.96;
      canvas.drawLine(
        center + Offset(math.cos(angle), math.sin(angle)) * inner,
        center + Offset(math.cos(angle), math.sin(angle)) * outer,
        stroke(
          base.withValues(alpha: k == 0 ? 0.14 : 0.07),
          k == 0 ? 2 : 1,
        ),
      );
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      t * math.pi * 2,
      math.pi / 3,
      false,
      stroke(accent.withValues(alpha: 0.16), 2),
    );
    final handAngle = t * math.pi * 2;
    canvas.drawLine(
      center,
      center + Offset(math.cos(handAngle), math.sin(handAngle)) * radius * 0.7,
      stroke(accent.withValues(alpha: 0.28), 1.6),
    );
  }
}

// ---------------- Text：纸页栅格渐入 + 光标闪烁 ----------------

class _TextBackdropPainter extends _BackdropPainterBase {
  _TextBackdropPainter({
    required super.animation,
    required super.accent,
    required super.seed,
    required super.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.clipRect(Offset.zero & size);

    // 背景栅格
    final grid = stroke(base.withValues(alpha: 0.025), 1);
    final gridStep = math.max(32.0, h / 12);
    for (var y = 0.0; y < h; y += gridStep) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    final pageW = math.min(w * 0.5, h * 0.62);
    final pageH = pageW * 1.32;
    final left = w * 0.5 - pageW / 2 - w * 0.06;
    final top = (h - pageH) / 2 + h * 0.02;

    // 后页
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + 14, top - 12, pageW, pageH),
        const Radius.circular(12),
      ),
      fill(base.withValues(alpha: 0.02)),
    );

    // 前页
    final pageRect = Rect.fromLTWH(left, top, pageW, pageH);
    final pageRRect = RRect.fromRectAndRadius(pageRect, const Radius.circular(12));
    canvas.drawRRect(pageRRect, fill(base.withValues(alpha: 0.026)));
    canvas.drawRRect(pageRRect, stroke(base.withValues(alpha: 0.07), 1));

    final pad = pageW * 0.1;
    // 左侧 accent 页边线
    canvas.drawLine(
      Offset(left + pad * 0.5, top + pad * 1.4),
      Offset(left + pad * 0.5, top + pageH - pad * 1.4),
      stroke(accent.withValues(alpha: 0.16), 2),
    );
    // 标题强调条
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + pad, top + pad, pageW * 0.38, 6),
        const Radius.circular(3),
      ),
      fill(accent.withValues(alpha: 0.22)),
    );

    // 文字行渐入
    const lines = 12;
    const lineStep = 0.058;
    const lineH = 5.5;
    for (var i = 0; i < lines; i++) {
      final appear = ((t + 0.55 - i * 0.045) * 8).clamp(0.0, 1.0);
      if (appear <= 0) continue;
      final lineW = pageW * (0.34 + rand(i * 3 + 1) * 0.46);
      final y = top + pageH * (0.18 + i * lineStep);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left + pad, y, lineW, lineH),
          const Radius.circular(2.75),
        ),
        fill(base.withValues(alpha: 0.11 * appear)),
      );
    }

    // 右下角折角
    final fold = pageW * 0.14;
    final foldPath = Path()
      ..moveTo(pageRect.right - fold, pageRect.bottom)
      ..lineTo(pageRect.right, pageRect.bottom - fold)
      ..lineTo(pageRect.right, pageRect.bottom)
      ..close();
    canvas.drawPath(foldPath, fill(base.withValues(alpha: 0.08)));

    // 光标闪烁
    final blink = (t * 6) % 1.0 < 0.5 ? 1.0 : 0.0;
    final cursorY = top + pageH * (0.18 + lines * lineStep);
    canvas.drawRect(
      Rect.fromLTWH(left + pad, cursorY, 2.5, 14),
      fill(accent.withValues(alpha: 0.32 * blink)),
    );
  }
}

// ---------------- Chat：层叠气泡 + 声波扩散 ----------------

class _ChatBackdropPainter extends _BackdropPainterBase {
  _ChatBackdropPainter({
    required super.animation,
    required super.accent,
    required super.seed,
    required super.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    canvas.clipRect(Offset.zero & size);

    // 声波扩散
    final waveCenter = Offset(w * 0.76, h * 0.32);
    final maxR = math.min(w, h) * 0.62;
    for (var k = 0; k < 4; k++) {
      final phase = (t + k / 4) % 1.0;
      canvas.drawCircle(
        waveCenter,
        maxR * phase,
        stroke(accent.withValues(alpha: 0.08 * (1 - phase)), 1.2),
      );
    }

    // 层叠对话气泡
    const bubbleCount = 3;
    for (var i = 0; i < bubbleCount; i++) {
      final bubbleW = w * (0.30 + rand(i * 11 + 1) * 0.18);
      final bubbleH = h * 0.11;
      final mine = i.isOdd;
      final x = mine ? w * 0.56 : w * (0.10 + rand(i * 11 + 3) * 0.06);
      final y = h * (0.22 + i * 0.18) +
          math.sin((t + i * 0.18) * math.pi * 2) * 4;
      final rect = Rect.fromLTWH(x, y, bubbleW, bubbleH);
      final radius = Radius.circular(bubbleH * 0.42);
      final bubbleColor =
          (mine ? accent : base).withValues(alpha: mine ? 0.07 : 0.045);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), fill(bubbleColor));
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        stroke(base.withValues(alpha: 0.05), 1),
      );

      // 气泡内文字线
      for (var k = 0; k < 2; k++) {
        final lineW = bubbleW * (0.28 + rand(i * 13 + k) * 0.34);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              rect.left + bubbleH * 0.5,
              rect.top + bubbleH * (0.3 + k * 0.3),
              lineW,
              bubbleH * 0.09,
            ),
            Radius.circular(bubbleH * 0.045),
          ),
          fill(base.withValues(alpha: 0.09)),
        );
      }

      // 前沿小头像圆点（左侧气泡）
      if (!mine) {
        final avatarR = math.max(2.0, bubbleH * 0.13);
        final avatarX = rect.left - avatarR * 1.9;
        canvas.drawCircle(
          Offset(avatarX, rect.center.dy - avatarR * 1.4),
          avatarR,
          fill(accent.withValues(alpha: 0.18)),
        );
        canvas.drawCircle(
          Offset(avatarX, rect.center.dy + avatarR * 1.4),
          avatarR,
          fill(base.withValues(alpha: 0.12)),
        );
      }

      // 气泡尾巴
      final tail = Path();
      if (mine) {
        tail
          ..moveTo(rect.right - bubbleH * 0.5, rect.bottom - 4)
          ..lineTo(rect.right - bubbleH * 0.1, rect.bottom + 6)
          ..lineTo(rect.right - bubbleH * 0.7, rect.bottom - 2)
          ..close();
      } else {
        tail
          ..moveTo(rect.left + bubbleH * 0.5, rect.bottom - 4)
          ..lineTo(rect.left + bubbleH * 0.1, rect.bottom + 6)
          ..lineTo(rect.left + bubbleH * 0.7, rect.bottom - 2)
          ..close();
      }
      canvas.drawPath(tail, fill(bubbleColor));
    }
  }
}
