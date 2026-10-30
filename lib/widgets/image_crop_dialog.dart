import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 图片自由剪裁对话框
///
/// 支持双指缩放 / 拖拽，中间为固定比例的剪裁框：
/// - 头像：1:1，输出 512×512
/// - 壁纸：屏幕比例，输出宽度不超过 1920
///
/// 返回裁剪后的文件路径；用户取消返回 null。
Future<String?> showImageCropDialog(
  BuildContext context, {
  required String sourcePath,
  required double aspectRatio,
  required String outputPath,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ImageCropPage(
        sourcePath: sourcePath,
        aspectRatio: aspectRatio,
        outputPath: outputPath,
      ),
    ),
  );
}

class _ImageCropPage extends StatefulWidget {
  const _ImageCropPage({
    required this.sourcePath,
    required this.aspectRatio,
    required this.outputPath,
  });

  final String sourcePath;
  final double aspectRatio;
  final String outputPath;

  @override
  State<_ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<_ImageCropPage> {
  final TransformationController _transform = TransformationController();

  /// 解码后的图片像素尺寸
  Size? _imageSize;

  /// 场景（图片在 InteractiveViewer 中的显示尺寸）
  Size _sceneSize = Size.zero;

  /// 裁剪框在视口中的位置
  Rect _cropRect = Rect.zero;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _loadImageSize() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _imageSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
      });
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 根据视口尺寸计算场景尺寸与裁剪框，并设置初始变换
  void _layout(Size viewport) {
    final image = _imageSize!;
    final imageAspect = image.width / image.height;

    // 场景尺寸：cover 整个视口（保证任何位置都有图）
    var sceneW = viewport.width;
    var sceneH = sceneW / imageAspect;
    if (sceneH < viewport.height) {
      sceneH = viewport.height;
      sceneW = sceneH * imageAspect;
    }
    _sceneSize = Size(sceneW, sceneH);

    // 裁剪框：宽度占视口 86%，受高度限制
    var cropW = viewport.width * 0.86;
    var cropH = cropW / widget.aspectRatio;
    final maxH = viewport.height * 0.7;
    if (cropH > maxH) {
      cropH = maxH;
      cropW = cropH * widget.aspectRatio;
    }
    _cropRect = Rect.fromCenter(
      center: Offset(viewport.width / 2, viewport.height / 2),
      width: cropW,
      height: cropH,
    );

    // 初始变换：让图片中心对齐裁剪框中心，且至少覆盖裁剪框
    final coverScale = math.max(
      _cropRect.width / _sceneSize.width,
      _cropRect.height / _sceneSize.height,
    );
    final scaledW = _sceneSize.width * coverScale;
    final scaledH = _sceneSize.height * coverScale;
    final dx = _cropRect.center.dx - scaledW / 2;
    final dy = _cropRect.center.dy - scaledH / 2;
    // 直接构造「缩放 + 平移」矩阵（列主序），避免使用已弃用的 translate/scale
    _transform.value = Matrix4(
      coverScale, 0, 0, 0,
      0, coverScale, 0, 0,
      0, 0, 1, 0,
      dx, dy, 0, 1,
    );
  }

  /// 执行裁剪：视口裁剪框 → 逆变换到场景 → 映射到图片像素 → 重绘输出
  Future<void> _confirm() async {
    if (_saving || _imageSize == null) return;
    setState(() => _saving = true);
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 视口坐标 → 场景坐标
      final inverse = Matrix4.inverted(_transform.value);
      final topLeft = MatrixUtils.transformPoint(inverse, _cropRect.topLeft);
      final bottomRight =
          MatrixUtils.transformPoint(inverse, _cropRect.bottomRight);
      var sceneRect = Rect.fromPoints(topLeft, bottomRight);

      // 场景坐标 → 图片像素坐标（裁剪到图片范围内）
      final pixelScale = image.width / _sceneSize.width;
      var src = Rect.fromLTRB(
        (sceneRect.left * pixelScale).clamp(0.0, image.width.toDouble()),
        (sceneRect.top * pixelScale).clamp(0.0, image.height.toDouble()),
        (sceneRect.right * pixelScale).clamp(0.0, image.width.toDouble()),
        (sceneRect.bottom * pixelScale).clamp(0.0, image.height.toDouble()),
      );
      if (src.width < 8 || src.height < 8) {
        throw StateError('裁剪区域过小');
      }

      // 输出尺寸：宽度限制（头像 512 / 壁纸 1920），保持裁剪比例
      final isAvatar = (widget.aspectRatio - 1.0).abs() < 0.01;
      final outW = math.min(
        src.width.round(),
        isAvatar ? 512 : 1920,
      ).clamp(16, 4096);
      final outH = (outW / widget.aspectRatio).round().clamp(16, 4096);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final outImage = await picture.toImage(outW, outH);
      final png =
          await outImage.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('编码失败');

      final outFile = File(widget.outputPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(png.buffer.asUint8List(), flush: true);
      if (mounted) Navigator.of(context).pop(widget.outputPath);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('裁剪失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('自由剪裁'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _confirm,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check, color: Colors.white),
            label: const Text('确定', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _imageSize == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final viewport =
                    Size(constraints.maxWidth, constraints.maxHeight);
                if (_sceneSize == Size.zero) {
                  // 首帧：完成布局计算后再渲染
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _layout(viewport));
                  });
                  return const SizedBox.shrink();
                }
                return Stack(
                  children: [
                    // 可缩放拖拽的图片
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 0.3,
                        maxScale: 6,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: SizedBox(
                          width: _sceneSize.width,
                          height: _sceneSize.height,
                          child: Image.file(
                            File(widget.sourcePath),
                            fit: BoxFit.fill,
                          ),
                        ),
                      ),
                    ),
                    // 裁剪框遮罩（不可交互）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _CropOverlayPainter(
                            cropRect: _cropRect,
                            isDark: isDark,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 24,
                      child: Text(
                        '双指缩放 · 单指拖拽，调整完成后点右上角「确定」',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// 裁剪框遮罩：四周压暗 + 中间高亮框
class _CropOverlayPainter extends CustomPainter {
  _CropOverlayPainter({required this.cropRect, required this.isDark});

  final Rect cropRect;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final full = Offset.zero & size;
    // evenOdd：整屏减去裁剪框，形成「洞」
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(full)
      ..addRRect(RRect.fromRectAndRadius(cropRect, const Radius.circular(8)));
    canvas.drawPath(path, dim);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.9);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cropRect, const Radius.circular(8)),
      border,
    );
  }

  @override
  bool shouldRepaint(_CropOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect;
}
