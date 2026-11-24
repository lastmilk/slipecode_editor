import 'dart:io';

import 'package:path/path.dart' as p;

import '../toolchain/toolchain_manager.dart';
import '../toolchain/toolchain_models.dart';
import 'lsp_client.dart';
import 'lsp_server_store.dart';

/// Dart 语言服务发现结果
class DartServerDiscoveryResult {
  final LspLaunchSpec? spec;

  /// 失败原因（供状态栏 / 设置页展示）
  final String? error;

  const DartServerDiscoveryResult({this.spec, this.error});

  bool get found => spec != null;
}

/// Dart / Flutter 语言服务自动发现
///
/// 解析顺序：工具链管理的 dart → Flutter 内置 dart-sdk → 系统 PATH。
/// 环境注入 `FLUTTER_ROOT` / `PUB_CACHE`，并校验 SDK 版本 ≥ 2.19。
class DartServerDiscovery {
  DartServerDiscovery._();

  static const int _minMajor = 2;
  static const int _minMinor = 19;

  static Future<DartServerDiscoveryResult> discover({
    String? projectPath,
  }) async {
    final manager = ToolchainManager.instance;
    final environment =
        manager.environment(projectPath: projectPath).build();
    final flutterRoot = environment['FLUTTER_ROOT'];

    String? dart = manager.resolveExecutable(
      ToolchainKind.dart,
      projectPath: projectPath,
    );
    dart ??= _bundledDart(flutterRoot);
    dart ??= _whichDart(environment['PATH']);
    if (dart == null || !File(dart).existsSync()) {
      return const DartServerDiscoveryResult(
        error: '未找到 dart 可执行文件，请先在「工具链」安装 Dart 或 Flutter',
      );
    }

    final version = await _dartVersion(dart, environment);
    if (version != null) {
      final parsed = _parseVersion(version);
      if (parsed != null &&
          (parsed.$1 < _minMajor ||
              (parsed.$1 == _minMajor && parsed.$2 < _minMinor))) {
        return DartServerDiscoveryResult(
          error: 'Dart SDK 版本过低（$version），语言服务需要 ≥ 2.19',
        );
      }
    }

    final config = LspServerStore.instance.dartConfig;
    return DartServerDiscoveryResult(
      spec: LspLaunchSpec(
        id: LspServerStore.dartServerId,
        name: config.name,
        executable: dart,
        args: config.args,
        workingDirectory: projectPath,
        environment: {
          if (flutterRoot != null) 'FLUTTER_ROOT': flutterRoot,
          if (environment['PUB_CACHE'] != null)
            'PUB_CACHE': environment['PUB_CACHE']!,
          if (environment['PATH'] != null) 'PATH': environment['PATH']!,
        },
        initializationOptions: config.initializationOptions,
        version: version,
      ),
    );
  }

  static String? _bundledDart(String? flutterRoot) {
    if (flutterRoot == null) return null;
    final name = Platform.isWindows ? 'dart.exe' : 'dart';
    final candidate = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', name);
    return File(candidate).existsSync() ? candidate : null;
  }

  static String? _whichDart(String? pathValue) {
    if (pathValue == null || pathValue.isEmpty) return null;
    final separator = Platform.isWindows ? ';' : ':';
    final name = Platform.isWindows ? 'dart.exe' : 'dart';
    for (final dir in pathValue.split(separator)) {
      if (dir.trim().isEmpty) continue;
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String?> _dartVersion(
    String dart,
    Map<String, String> environment,
  ) async {
    try {
      final result = await Process.run(
        dart,
        const ['--version'],
        environment: environment,
        runInShell: Platform.isWindows,
      ).timeout(const Duration(seconds: 15));
      // dart --version 输出到 stdout（新版本）或 stderr（旧版本）
      final text = '${result.stdout}\n${result.stderr}'.trim();
      final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(text);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  static (int, int)? _parseVersion(String version) {
    final parts = version.split('.');
    if (parts.length < 2) return null;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    if (major == null || minor == null) return null;
    return (major, minor);
  }
}
