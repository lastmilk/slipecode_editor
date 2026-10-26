import 'package:flutter/foundation.dart';

import '../services/container_service.dart';

/// proot 容器状态管理
class ContainerProvider extends ChangeNotifier {
  final ContainerService _service = ContainerService.instance;

  bool _initialized = false;
  bool _checking = true;
  bool _ready = false;
  bool _rootfsInstalled = false;
  bool _busy = false;

  String? _prootPath;
  String _arch = '';
  double? _progress;
  String _status = '';
  String? _error;

  final List<String> _logs = [];

  bool get initialized => _initialized;
  bool get checking => _checking;
  bool get ready => _ready;
  bool get rootfsInstalled => _rootfsInstalled;
  bool get busy => _busy;
  String? get prootPath => _prootPath;
  String get arch => _arch;
  double? get progress => _progress;
  String get status => _status;
  String? get error => _error;
  List<String> get logs => List.unmodifiable(_logs);

  String get rootfsPath => _service.rootfsPath;
  String get envRootPath => _service.envRootPath;

  /// 检查容器状态
  Future<void> refresh() async {
    _checking = true;
    _error = null;
    notifyListeners();

    try {
      await _service.init();
      _initialized = true;
      _arch = await _service.getDeviceArch();
      _prootPath = await _service.resolveProotPath();
      _rootfsInstalled = await _service.isRootfsInstalled();
      _ready = _prootPath != null && _rootfsInstalled;
    } catch (e) {
      _error = '环境检查失败：$e';
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void _log(String message) {
    _logs.add(message);
    if (_logs.length > 500) {
      _logs.removeRange(0, _logs.length - 500);
    }
    notifyListeners();
  }

  void _setBusy(bool value, {String status = ''}) {
    _busy = value;
    _status = status;
    if (!value) _progress = null;
    notifyListeners();
  }

  /// 下载安装 proot
  Future<bool> installProotFromUrl(String url) async {
    if (url.trim().isEmpty) {
      _error = '请输入 proot 下载地址';
      notifyListeners();
      return false;
    }
    _setBusy(true, status: '正在安装 proot...');
    try {
      await _service.installProotFromUrl(
        url.trim(),
        onLog: _log,
        onProgress: (value) {
          _progress = value;
          notifyListeners();
        },
      );
      await refresh();
      return _prootPath != null;
    } catch (e) {
      _error = '$e';
      _log('安装失败：$e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 从本地文件导入 proot
  Future<bool> installProotFromFile(String path) async {
    _setBusy(true, status: '正在导入 proot...');
    try {
      await _service.installProotFromFile(path, onLog: _log);
      await refresh();
      return _prootPath != null;
    } catch (e) {
      _error = '$e';
      _log('导入失败：$e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 下载安装 rootfs
  Future<bool> installRootfsFromUrl(String url) async {
    _setBusy(true, status: '正在安装 rootfs...');
    try {
      await _service.installRootfsFromUrl(
        url.trim(),
        onLog: _log,
        onProgress: (value) {
          _progress = value;
          notifyListeners();
        },
      );
      await refresh();
      return _rootfsInstalled;
    } catch (e) {
      _error = '$e';
      _log('安装失败：$e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 从本地 tar.gz 导入 rootfs
  Future<bool> installRootfsFromFile(String archivePath) async {
    _setBusy(true, status: '正在导入 rootfs...');
    try {
      await _service.installRootfsFromFile(archivePath, onLog: _log);
      await refresh();
      return _rootfsInstalled;
    } catch (e) {
      _error = '$e';
      _log('导入失败：$e');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> clearLogs() async {
    _logs.clear();
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
