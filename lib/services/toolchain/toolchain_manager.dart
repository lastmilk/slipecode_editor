import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../desktop_prefs_service.dart';
import 'archive_extractor.dart';
import 'toolchain_catalog_service.dart';
import 'toolchain_downloader.dart';
import 'toolchain_environment.dart';
import 'toolchain_models.dart';

class ToolchainException implements Exception {
  final String message;

  const ToolchainException(this.message);

  @override
  String toString() => message;
}

/// 工具链安装、切换与解析。
///
/// 安装目录：`<appSupport>/toolchains/<kind>/<version>/`
/// 临时目录：`<appSupport>/toolchains/.tmp/<kind>-<version>/`
class ToolchainManager {
  ToolchainManager._();

  static final ToolchainManager instance = ToolchainManager._();

  final ToolchainCatalogService catalog = ToolchainCatalogService();
  final ToolchainDownloader _downloader = ToolchainDownloader();
  final ArchiveExtractor _extractor = const ArchiveExtractor();

  final List<InstalledToolchain> _installed = [];

  Directory? _root;
  String _appSupportPath = '';
  Future<void>? _initFuture;

  List<InstalledToolchain> get installed => List.unmodifiable(_installed);

  String get appSupportPath => _appSupportPath;

  Future<void> initialize() {
    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    final support = await getApplicationSupportDirectory();
    _appSupportPath = support.path;
    final root = Directory(p.join(support.path, 'toolchains'));
    await root.create(recursive: true);
    _root = root;
    // 上次异常退出可能留下临时目录
    final tmp = Directory(p.join(root.path, '.tmp'));
    if (await tmp.exists()) {
      try {
        await tmp.delete(recursive: true);
      } catch (e) {
        debugPrint('清理工具链临时目录失败：$e');
      }
    }
    await _loadManifest();
  }

  List<InstalledToolchain> installedOf(ToolchainKind kind) {
    final list = _installed.where((item) => item.kind == kind).toList();
    list.sort((a, b) => compareVersions(b.version, a.version));
    return list;
  }

  InstalledToolchain? find(ToolchainKind kind, String version) {
    return _installed
        .where((item) => item.kind == kind && item.version == version)
        .firstOrNull;
  }

  // ---------------------------------------------------------------------------
  // 安装 / 卸载
  // ---------------------------------------------------------------------------

  Future<InstalledToolchain> install(
    ToolchainRelease release, {
    required void Function(ToolchainProgress progress) onProgress,
    required ToolchainCancelToken cancelToken,
  }) async {
    await initialize();
    final root = _root!;
    final existing = find(release.kind, release.version);
    if (existing != null && existing.isIntact) {
      onProgress(ToolchainProgress(
        kind: release.kind,
        version: release.version,
        phase: ToolchainPhase.done,
        message: '已安装',
      ));
      return existing;
    }
    if (existing != null) {
      // 目录损坏：先移除记录，安装完成后重新登记
      _installed.remove(existing);
    }

    final tmpDir = Directory(p.join(
      root.path,
      '.tmp',
      '${release.kind.id}-${release.version}',
    ));
    final archive = File(p.join(tmpDir.path, release.fileName));

    void emit(
      ToolchainPhase phase, {
      int received = 0,
      int total = 0,
      String message = '',
    }) {
      onProgress(ToolchainProgress(
        kind: release.kind,
        version: release.version,
        phase: phase,
        received: received,
        total: total,
        message: message,
      ));
    }

    try {
      await tmpDir.create(recursive: true);
      emit(ToolchainPhase.downloading);

      // 下载（失败时由 UI 层决定是否切换镜像重试）
      await _downloader.download(
        url: release.url,
        destination: archive,
        cancelToken: cancelToken,
        onProgress: (received, total) => emit(
          ToolchainPhase.downloading,
          received: received,
          total: total,
        ),
      );
      cancelToken.throwIfCancelled();

      emit(ToolchainPhase.verifying);
      final verified = await _downloader.verifySha256(archive, release.sha256);
      if (!verified) {
        throw const ToolchainException('SHA-256 校验失败，文件可能损坏，请重试');
      }

      emit(ToolchainPhase.extracting);
      final extractDir = Directory(p.join(tmpDir.path, 'extract'));
      final contentRoot = await _extractor.extract(
        archive: archive,
        destDir: extractDir,
        cancelToken: cancelToken,
      );
      cancelToken.throwIfCancelled();

      emit(ToolchainPhase.installing);
      final target = Directory(p.join(
        root.path,
        release.kind.id,
        release.version,
      ));
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await target.parent.create(recursive: true);
      await contentRoot.rename(target.path);

      final smoke = await _smokeTest(release.kind, target);
      final record = InstalledToolchain(
        kind: release.kind,
        version: release.version,
        path: target.path,
        installedAt: DateTime.now().millisecondsSinceEpoch,
        smoke: smoke,
      );
      _installed.add(record);
      await _saveManifest();
      emit(ToolchainPhase.done, message: smoke);
      return record;
    } on ToolchainCancelledException {
      emit(ToolchainPhase.cancelled);
      rethrow;
    } catch (e) {
      emit(ToolchainPhase.failed, message: '$e');
      rethrow;
    } finally {
      try {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      } catch (e) {
        debugPrint('清理安装临时目录失败：$e');
      }
    }
  }

  Future<void> uninstall(InstalledToolchain toolchain) async {
    await initialize();
    try {
      final dir = Directory(toolchain.path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      throw ToolchainException('删除安装目录失败：$e');
    }
    _installed.removeWhere(
      (item) =>
          item.kind == toolchain.kind && item.version == toolchain.version,
    );
    final prefs = DesktopPrefsService.instance;
    prefs.update(() {
      if (prefs.defaultToolchains[toolchain.kind.id] == toolchain.version) {
        prefs.defaultToolchains.remove(toolchain.kind.id);
      }
    });
    await _saveManifest();
  }

  /// 重新执行冒烟测试，返回版本输出；失败时抛异常。
  Future<String> verify(InstalledToolchain toolchain) async {
    await initialize();
    final dir = Directory(toolchain.path);
    if (!await dir.exists()) {
      throw const ToolchainException('安装目录不存在');
    }
    return _smokeTest(toolchain.kind, dir);
  }

  Future<String> _smokeTest(ToolchainKind kind, Directory installDir) async {
    final executable = File(p.join(installDir.path, kind.executableRelative));
    if (!await executable.exists()) {
      throw ToolchainException(
        '安装包缺少可执行文件：${kind.executableRelative}',
      );
    }
    final env = environment().build();
    ProcessResult result;
    try {
      if (Platform.isWindows &&
          executable.path.toLowerCase().endsWith('.bat')) {
        result = await Process.run(
          executable.path,
          kind.versionArgs,
          workingDirectory: installDir.path,
          environment: env,
          runInShell: true,
        ).timeout(const Duration(seconds: 180));
      } else {
        result = await Process.run(
          executable.path,
          kind.versionArgs,
          workingDirectory: installDir.path,
          environment: env,
        ).timeout(const Duration(seconds: 180));
      }
    } on TimeoutException {
      throw const ToolchainException('版本检查超时（180s）');
    }
    final output = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0) {
      throw ToolchainException(
        '版本检查失败（exit ${result.exitCode}）：$output',
      );
    }
    return output;
  }

  // ---------------------------------------------------------------------------
  // 默认版本 / 项目固定 / 解析
  // ---------------------------------------------------------------------------

  void setDefault(ToolchainKind kind, String? version) {
    final prefs = DesktopPrefsService.instance;
    prefs.update(() {
      if (version == null || version.isEmpty) {
        prefs.defaultToolchains.remove(kind.id);
      } else {
        prefs.defaultToolchains[kind.id] = version;
      }
    });
  }

  String? defaultVersion(ToolchainKind kind) =>
      DesktopPrefsService.instance.defaultToolchains[kind.id];

  void pinProject(ToolchainKind kind, String projectPath, String? version) {
    DesktopPrefsService.instance.setToolchainPin(kind.id, projectPath, version);
  }

  /// 项目固定版本：偏好设置优先，其次只读兼容 `.fvmrc` / `.nvmrc` / `.node-version`。
  String? pinnedVersion(ToolchainKind kind, String? projectPath) {
    if (projectPath == null || projectPath.isEmpty) return null;
    final configured = DesktopPrefsService.instance.toolchainPin(
      kind.id,
      projectPath,
    );
    if (configured != null && configured.isNotEmpty) return configured;
    return _readVersionFile(kind, projectPath);
  }

  String? _readVersionFile(ToolchainKind kind, String projectPath) {
    try {
      switch (kind) {
        case ToolchainKind.flutter:
          final fvmrc = File(p.join(projectPath, '.fvmrc'));
          if (!fvmrc.existsSync()) return null;
          final raw = fvmrc.readAsStringSync().trim();
          if (raw.startsWith('{')) {
            final data = jsonDecode(raw);
            if (data is Map) {
              final value = data['flutter'];
              if (value is String) return value.trim();
            }
            return null;
          }
          return raw.isEmpty ? null : raw;
        case ToolchainKind.node:
          for (final name in const ['.nvmrc', '.node-version']) {
            final file = File(p.join(projectPath, name));
            if (!file.existsSync()) continue;
            final value = file.readAsStringSync().trim();
            if (value.isNotEmpty) return value;
          }
          return null;
        case ToolchainKind.dart:
          final file = File(p.join(projectPath, '.dart-version'));
          if (!file.existsSync()) return null;
          final value = file.readAsStringSync().trim();
          return value.isEmpty ? null : value;
        case ToolchainKind.java:
          return null;
        case ToolchainKind.python:
          // .python-version 与 pyenv 约定一致
          final file = File(p.join(projectPath, '.python-version'));
          if (!file.existsSync()) return null;
          final value = file.readAsStringSync().trim();
          return value.isEmpty ? null : value;
      }
    } catch (e) {
      debugPrint('读取项目工具链版本文件失败：$e');
      return null;
    }
  }

  /// 解析实际使用的可执行文件路径（项目固定 → 默认 → 已安装最新 → 系统）。
  String? resolveExecutable(ToolchainKind kind, {String? projectPath}) {
    final pinned = pinnedVersion(kind, projectPath);
    if (pinned != null) {
      final record = _installed
          .where((item) => item.kind == kind && item.version == pinned)
          .firstOrNull;
      if (record != null && record.isIntact) return record.executablePath;
    }
    final defaultVersion = this.defaultVersion(kind);
    if (defaultVersion != null) {
      final record = find(kind, defaultVersion);
      if (record != null && record.isIntact) return record.executablePath;
    }
    final installed = installedOf(kind);
    if (installed.isNotEmpty) {
      final intact = installed.where((item) => item.isIntact).firstOrNull;
      if (intact != null) return intact.executablePath;
    }
    return systemExecutable(kind);
  }

  /// 从系统 PATH 中查找已安装的同名工具。
  String? systemExecutable(ToolchainKind kind) {
    final executable = kind.executableRelative.split('/').last;
    final separator = Platform.isWindows ? ';' : ':';
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(separator)) {
      if (dir.trim().isEmpty) continue;
      final candidate = File(p.join(dir, executable));
      if (candidate.existsSync()) return candidate.path;
    }
    if (kind == ToolchainKind.flutter) {
      final root = Platform.environment['FLUTTER_ROOT'];
      if (root != null && root.isNotEmpty) {
        final candidate = File(p.join(root, kind.executableRelative));
        if (candidate.existsSync()) return candidate.path;
      }
    }
    return null;
  }

  /// 当前生效版本（用于状态栏 / 构建页）。
  String? activeVersion(ToolchainKind kind, {String? projectPath}) {
    final executable = resolveExecutable(kind, projectPath: projectPath);
    if (executable == null) return null;
    final match = _installed
        .where((item) => item.executablePath == executable)
        .firstOrNull;
    return match?.version;
  }

  ToolchainEnvironment environment({String? projectPath}) {
    return ToolchainEnvironment(
      resolvePath: (kind) => resolveExecutable(kind, projectPath: projectPath),
      appSupportPath:
          _appSupportPath.isNotEmpty ? _appSupportPath : Directory.systemTemp.path,
      useMirror: DesktopPrefsService.instance.toolchainMirror == 'cn',
    );
  }

  // ---------------------------------------------------------------------------
  // 磁盘占用 / 清单
  // ---------------------------------------------------------------------------

  Future<int> diskUsage() async {
    await initialize();
    final root = _root;
    if (root == null) return 0;
    var total = 0;
    try {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // 忽略单个文件统计失败
          }
        }
      }
    } catch (e) {
      debugPrint('统计工具链磁盘占用失败：$e');
    }
    return total;
  }

  Future<void> _loadManifest() async {
    final root = _root;
    if (root == null) return;
    final file = File(p.join(root.path, 'manifest.json'));
    if (!await file.exists()) return;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final list = raw['installed'];
      if (list is! List) return;
      _installed
        ..clear()
        ..addAll(list
            .whereType<Map>()
            .map((item) => InstalledToolchain.fromJson(
                  item.cast<String, dynamic>(),
                ))
            .whereType<InstalledToolchain>());
    } catch (e) {
      debugPrint('读取工具链清单失败：$e');
    }
  }

  Future<void> _saveManifest() async {
    final root = _root;
    if (root == null) return;
    final file = File(p.join(root.path, 'manifest.json'));
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'installed': _installed.map((item) => item.toJson()).toList(),
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('保存工具链清单失败：$e');
    }
  }
}
