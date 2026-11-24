import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ondemand_resource.dart';

/// 单个资源的安装状态。
enum ResourceInstallStatus { unknown, missing, downloading, installed, failed }

/// 资源状态快照（供 UI 监听）。
@immutable
class ResourceState {
  const ResourceState({
    this.status = ResourceInstallStatus.unknown,
    this.progress = 0,
    this.message,
  });

  final ResourceInstallStatus status;

  /// 0~1，下载/解压进度。
  final double progress;

  /// 失败原因或当前阶段说明。
  final String? message;

  bool get isInstalled => status == ResourceInstallStatus.installed;
  bool get isBusy => status == ResourceInstallStatus.downloading;

  ResourceState copyWith({
    ResourceInstallStatus? status,
    double? progress,
    String? message,
  }) {
    return ResourceState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
    );
  }
}

/// 按需下载服务：管理 OnlyOffice / Dify / HyperFrames / Blender 等内核。
///
/// 概念版下载源默认走本地服务器（可在「资源」入口中修改），
/// 本地服务器不可用时回退为 GitHub 镜像仓库克隆（gh-proxy 加速）。
class ResourceDownloadService extends ChangeNotifier {
  ResourceDownloadService._();

  static final ResourceDownloadService instance = ResourceDownloadService._();

  static const String _prefsServer = 'resources.local_server';
  static const String _prefsInstalled = 'resources.installed';
  static const String _prefsEnabled = 'resources.enabled';

  /// 官方按需下载源（宝塔服务器，提供 `<id>.zip`）。
  static const String _defaultServer = 'https://api.slipe.linjade.com/ondemand';

  final Map<String, ResourceState> _states = {};
  final Set<String> _installed = {};

  bool _loaded = false;
  Directory? _rootDir;

  /// 默认下载源地址。
  String get defaultServerUrl => _defaultServer;

  /// 当前下载源地址。
  String _serverUrl = _defaultServer;
  String get serverUrl => _serverUrl;

  /// 是否启用按需下载（关闭后不再自动提示与下载内核）。
  bool _enabled = true;
  bool get enabled => _enabled;

  /// 是否已完成本地状态加载。
  bool get loaded => _loaded;

  ResourceState stateOf(String id) =>
      _states[id] ?? const ResourceState(status: ResourceInstallStatus.missing);

  bool isInstalled(String id) => _installed.contains(id);

  /// 尚未安装的资源。
  List<OnDemandResource> get missing => OnDemandResources.all
      .where((resource) => !_installed.contains(resource.id))
      .toList(growable: false);

  /// 某个场景缺失的资源。
  List<OnDemandResource> missingForScene(String sceneId) =>
      OnDemandResources.forScene(
        sceneId,
      ).where((resource) => !_installed.contains(resource.id)).toList();

  /// 已安装资源所在目录（资源未安装时为 null）。
  Future<String?> installPath(String id) async {
    if (!_installed.contains(id)) return null;
    final root = await _ensureRootDir();
    return p.join(root.path, id);
  }

  /// 加载本地状态（幂等）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_prefsServer)?.trim().isNotEmpty == true
        ? prefs.getString(_prefsServer)!.trim()
        : _defaultServer;
    _enabled = prefs.getBool(_prefsEnabled) ?? true;
    _installed
      ..clear()
      ..addAll(prefs.getStringList(_prefsInstalled) ?? const []);

    // 目录存在即视为已安装，避免用户手动清理磁盘后状态不一致。
    final root = await _ensureRootDir();
    for (final resource in OnDemandResources.all) {
      final dir = Directory(p.join(root.path, resource.id));
      final marker = File(p.join(dir.path, '.slipe-installed.json'));
      if (await marker.exists()) {
        _installed.add(resource.id);
        _states[resource.id] = const ResourceState(
          status: ResourceInstallStatus.installed,
          progress: 1,
        );
      } else {
        _installed.remove(resource.id);
        _states[resource.id] = const ResourceState(
          status: ResourceInstallStatus.missing,
        );
      }
    }
    notifyListeners();
  }

  /// 修改下载源地址。
  Future<void> setServerUrl(String url) async {
    final normalized = url.trim().isEmpty ? _defaultServer : url.trim();
    _serverUrl = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsServer, normalized);
    notifyListeners();
  }

  /// 启用 / 关闭按需下载。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    notifyListeners();
  }

  /// 下载并安装资源。
  ///
  /// 优先从 [serverUrl] 拉取 `<id>.zip`；失败时回退为镜像仓库克隆。
  Future<bool> download(String id) async {
    if (!_enabled) {
      _update(
        id,
        const ResourceState(
          status: ResourceInstallStatus.failed,
          progress: 0,
          message: '按需下载已关闭，可在资源面板中重新开启',
        ),
      );
      return false;
    }
    final resource = OnDemandResources.byId(id);
    if (resource == null) return false;
    if (_states[id]?.isBusy ?? false) return false;

    _update(
      id,
      const ResourceState(
        status: ResourceInstallStatus.downloading,
        progress: 0,
        message: '准备下载…',
      ),
    );

    final root = await _ensureRootDir();
    final targetDir = Directory(p.join(root.path, id));
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    var ok = await _downloadZip(resource, targetDir);
    if (!ok) {
      ok = await _cloneRepository(resource, targetDir);
    }

    if (!ok) {
      _update(
        id,
        ResourceState(
          status: ResourceInstallStatus.failed,
          progress: 0,
          message:
              '下载失败：请确认本地资源服务器（$_serverUrl）可用，或手动执行\n'
              'git clone ${resource.mirrorUrl}',
        ),
      );
      return false;
    }

    final marker = File(p.join(targetDir.path, '.slipe-installed.json'));
    await marker.writeAsString(
      jsonEncode({
        'id': resource.id,
        'name': resource.name,
        'repo': resource.repoUrl,
        'installedAt': DateTime.now().toIso8601String(),
      }),
    );

    _installed.add(id);
    _states[id] = const ResourceState(
      status: ResourceInstallStatus.installed,
      progress: 1,
      message: '已安装',
    );
    notifyListeners();
    await _persistInstalled();
    return true;
  }

  /// 卸载资源。
  Future<void> remove(String id) async {
    if (_states[id]?.isBusy ?? false) return;
    final root = await _ensureRootDir();
    final dir = Directory(p.join(root.path, id));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('删除资源失败：$e');
    }
    _installed.remove(id);
    _states[id] = const ResourceState(status: ResourceInstallStatus.missing);
    notifyListeners();
    await _persistInstalled();
  }

  // ---------------- 内部实现 ----------------

  Future<Directory> _ensureRootDir() async {
    if (_rootDir != null) return _rootDir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'ondemand_resources'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _rootDir = dir;
    return dir;
  }

  void _update(String id, ResourceState state) {
    _states[id] = state;
    notifyListeners();
  }

  Future<void> _persistInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsInstalled, _installed.toList());
  }

  /// 从本地资源服务器下载 zip 并解压。
  ///
  /// 除 HTTP 外，[serverUrl] 也支持本地目录：
  /// - 目录下存在 `<id>.zip` 时直接解压；
  /// - 目录下存在 `<id>/` 子目录时直接拷贝。
  Future<bool> _downloadZip(OnDemandResource resource, Directory targetDir) async {
    // 先尝试本地目录源（离线可用）。
    if (await _copyFromLocalDirectory(resource, targetDir)) return true;

    final uri = Uri.tryParse(
      '${_serverUrl.replaceAll(RegExp(r'/+$'), '')}/${resource.id}.zip',
    );
    if (uri == null) return false;

    final client = http.Client();
    File? zipFile;
    try {
      final request = http.Request('GET', uri);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('资源服务器返回 ${response.statusCode}：$uri');
        return false;
      }

      final total = response.contentLength ?? 0;
      final tempDir = await getTemporaryDirectory();
      zipFile = File(p.join(tempDir.path, '${resource.id}.zip'));
      final sink = zipFile.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _update(
            resource.id,
            ResourceState(
              status: ResourceInstallStatus.downloading,
              // 下载占 90%，解压占剩余 10%
              progress: (received / total) * 0.9,
              message: '下载中 ${(received / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
          );
        }
      }
      await sink.flush();
      await sink.close();

      _update(
        resource.id,
        const ResourceState(
          status: ResourceInstallStatus.downloading,
          progress: 0.92,
          message: '解压中…',
        ),
      );
      await extractFileToDisk(zipFile.path, targetDir.path);
      return true;
    } catch (e) {
      debugPrint('从本地服务器下载资源失败：$e');
      return false;
    } finally {
      client.close();
      try {
        if (zipFile != null && await zipFile.exists()) {
          await zipFile.delete();
        }
      } catch (_) {
        // 临时文件清理失败不影响结果
      }
    }
  }

  /// 从本地目录安装资源（[serverUrl] 为目录路径或 file:// 时生效）。
  Future<bool> _copyFromLocalDirectory(
    OnDemandResource resource,
    Directory targetDir,
  ) async {
    final raw = _serverUrl.startsWith('file://')
        ? Uri.parse(_serverUrl).toFilePath()
        : _serverUrl;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return false;

    final sourceDir = Directory(raw);
    if (!await sourceDir.exists()) return false;

    try {
      final zip = File(p.join(sourceDir.path, '${resource.id}.zip'));
      if (await zip.exists()) {
        _update(
          resource.id,
          const ResourceState(
            status: ResourceInstallStatus.downloading,
            progress: 0.5,
            message: '从本地目录解压…',
          ),
        );
        await extractFileToDisk(zip.path, targetDir.path);
        return true;
      }

      final subDir = Directory(p.join(sourceDir.path, resource.id));
      if (await subDir.exists()) {
        _update(
          resource.id,
          const ResourceState(
            status: ResourceInstallStatus.downloading,
            progress: 0.5,
            message: '从本地目录复制…',
          ),
        );
        await for (final entity in subDir.list(recursive: true)) {
          final relative = p.relative(entity.path, from: subDir.path);
          if (entity is File) {
            final dest = File(p.join(targetDir.path, relative));
            await dest.parent.create(recursive: true);
            await entity.copy(dest.path);
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('从本地目录安装资源失败：$e');
      return false;
    }
  }

  /// 兜底：通过镜像站浅克隆仓库。
  Future<bool> _cloneRepository(
    OnDemandResource resource,
    Directory targetDir,
  ) async {
    try {
      _update(
        resource.id,
        const ResourceState(
          status: ResourceInstallStatus.downloading,
          progress: 0,
          message: '本地资源服务器不可用，改用镜像仓库克隆…',
        ),
      );
      final process = await Process.start('git', [
        'clone',
        '--depth',
        '1',
        '--progress',
        resource.mirrorUrl,
        targetDir.path,
      ]);
      process.stdout.transform(utf8.decoder).listen((_) {});
      process.stderr.transform(utf8.decoder).listen((line) {
        final match = RegExp(r'(\d+)%').firstMatch(line);
        if (match != null) {
          final percent = int.tryParse(match.group(1) ?? '') ?? 0;
          _update(
            resource.id,
            ResourceState(
              status: ResourceInstallStatus.downloading,
              progress: (percent / 100) * 0.95,
              message: '镜像克隆中 $percent%',
            ),
          );
        }
      });
      final code = await process.exitCode;
      if (code != 0) {
        debugPrint('git clone 退出码：$code');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('镜像克隆失败（可能未安装 git）：$e');
      return false;
    }
  }
}
