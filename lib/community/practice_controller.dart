import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_globals.dart';
import '../services/practice_service.dart';
import 'practice_catalog.dart';
import 'practice_floating_ball.dart';

/// 教学模式会话（全局单例）
class PracticeController extends ChangeNotifier {
  PracticeController._();

  static final PracticeController instance = PracticeController._();

  PracticeSpec? _spec;
  String? _projectPath;
  PracticeCheckResult? _result;
  bool _checking = false;
  bool _notifiedPass = false;
  OverlayEntry? _overlay;
  Timer? _timer;
  Future<void> Function()? _beforeCheck;

  PracticeSpec? get spec => _spec;
  String? get projectPath => _projectPath;
  PracticeCheckResult? get result => _result;
  bool get active => _spec != null;
  bool get checking => _checking;

  /// 进入教学模式：创建临时项目并显示应用内悬浮球
  Future<void> start(
    BuildContext context,
    PracticeSpec spec, {
    Future<void> Function()? beforeCheck,
  }) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    if (active) await exit();
    _beforeCheck = beforeCheck;
    final projectPath = await PracticeService.instance.createProject(spec);
    _spec = spec;
    _projectPath = projectPath;
    _result = null;
    _checking = false;
    _notifiedPass = false;

    _overlay = OverlayEntry(builder: (_) => const PracticeFloatingBall());
    overlay.insert(_overlay!);
    _timer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => autoCheck(),
    );
    notifyListeners();
  }

  /// 自动检查（静默执行，用于悬浮球状态与通过提醒）
  Future<void> autoCheck() async {
    if (!active || _checking) return;
    await check(silent: true);
  }

  /// 检查当前代码
  Future<PracticeCheckResult?> check({bool silent = false}) async {
    final spec = _spec;
    final path = _projectPath;
    if (spec == null || path == null) return null;
    if (_checking) return _result;
    _checking = true;
    if (!silent) notifyListeners();
    try {
      // 先保存编辑器中的改动，确保检查读到最新代码
      await _beforeCheck?.call();
      final result = await PracticeService.instance.check(path, spec);
      _result = result;
      if (result.passed && !_notifiedPass) {
        _notifiedPass = true;
        _showPassedToast();
      }
      return result;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 强制退出教学模式（保留临时练习项目）
  Future<void> exit() async {
    _timer?.cancel();
    _timer = null;
    _overlay?.remove();
    _overlay = null;
    _spec = null;
    _projectPath = null;
    _result = null;
    _checking = false;
    _notifiedPass = false;
    _beforeCheck = null;
    notifyListeners();
  }

  void _showPassedToast() {
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('检测通过：本次实操已完成'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );
  }
}
