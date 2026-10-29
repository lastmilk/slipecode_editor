import 'dart:io';

import 'package:flutter/material.dart';

import '../services/overlay_service.dart';

/// IDE 右下角 AI 悬浮球
///
/// 应用内悬浮球（所有平台支持）：
/// - 可拖拽调整位置
/// - 点击后执行 [onTap]（通常是打开侧边栏 Agent 面板）
///
/// 系统级悬浮球（仅 Android）由 [OverlayService] 单独管理，
/// 在偏好设置中开启后即使 App 退到后台也能显示。
class AiFloatingBall extends StatefulWidget {
  const AiFloatingBall({super.key, required this.onTap});

  /// 点击悬浮球回调
  final VoidCallback onTap;

  @override
  State<AiFloatingBall> createState() => _AiFloatingBallState();
}

class _AiFloatingBallState extends State<AiFloatingBall>
    with SingleTickerProviderStateMixin {
  /// 距右下角的偏移（可被拖拽改变）
  double _dx = 16;
  double _dy = 96;

  /// 是否正在拖拽（拖拽时不触发点击）
  bool _dragging = false;

  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    // 呼吸动画：轻微缩放提示可点击
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const ballSize = 52.0;

    return Positioned(
      right: _dx,
      bottom: _dy,
      child: GestureDetector(
        onPanStart: (_) => _dragging = false,
        onPanUpdate: (details) {
          setState(() {
            _dragging = true;
            _dx = (_dx - details.delta.dx).clamp(0.0, size.width - ballSize);
            _dy = (_dy - details.delta.dy).clamp(0.0, size.height - ballSize);
          });
        },
        onTap: () {
          // 拖拽结束后的抬起不算点击
          if (!_dragging) widget.onTap();
        },
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.0, end: 1.08).animate(
            CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
          ),
          child: Container(
            width: ballSize,
            height: ballSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0175C2), Color(0xFF13B9FD)], // Flutter 蓝
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0175C2).withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }
}

/// 系统悬浮球的偏好设置开关辅助
///
/// 在设置页切换「系统悬浮球」时调用：
/// - 开启：检查/请求权限 → 启动前台服务显示悬浮球
/// - 关闭：停止前台服务
///
/// 返回最终结果（是否已开启）。
Future<bool> toggleSystemOverlay(bool enable) async {
  // iOS 不支持系统悬浮窗
  if (!Platform.isAndroid) return false;

  final service = OverlayService.instance;
  if (enable) {
    var granted = await service.checkPermission();
    if (!granted) {
      await service.requestPermission();
      // 用户从设置页返回后可能已授权；这里再查一次
      granted = await service.checkPermission();
    }
    if (!granted) return false;
    return service.show();
  } else {
    await service.hide();
    return false;
  }
}
