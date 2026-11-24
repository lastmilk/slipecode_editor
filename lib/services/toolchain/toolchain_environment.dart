import 'dart:io';

import 'package:path/path.dart' as p;

import 'toolchain_models.dart';

/// 工具链可执行文件解析器（由 [ToolchainManager] 提供）。
typedef ToolchainPathResolver = String? Function(ToolchainKind kind);

/// 统一生成子进程环境变量，供本地构建、LSP、终端、MCP 共用。
class ToolchainEnvironment {
  final ToolchainPathResolver resolvePath;

  /// 应用支持目录（`<appSupport>`），用于 PUB_CACHE / GRADLE_USER_HOME
  final String appSupportPath;

  /// 是否使用国内镜像（pub / flutter storage）
  final bool useMirror;

  const ToolchainEnvironment({
    required this.resolvePath,
    required this.appSupportPath,
    required this.useMirror,
  });

  /// 在 [base]（默认当前进程环境）之上叠加工具链变量。
  Map<String, String> build({Map<String, String>? base}) {
    final env = <String, String>{...(base ?? Platform.environment)};
    final separator = Platform.isWindows ? ';' : ':';

    // PATH：把已解析的工具链 bin 目录放到最前面
    final pathEntries = <String>[];
    final seen = <String>{};
    void addPath(String? executable) {
      if (executable == null) return;
      final dir = p.dirname(executable);
      if (dir.isEmpty || !seen.add(dir)) return;
      pathEntries.add(dir);
    }

    final flutter = resolvePath(ToolchainKind.flutter);
    final dart = resolvePath(ToolchainKind.dart);
    final node = resolvePath(ToolchainKind.node);
    final java = resolvePath(ToolchainKind.java);
    final python = resolvePath(ToolchainKind.python);
    addPath(node);
    addPath(java);
    addPath(python);
    addPath(flutter);
    addPath(dart);
    if (flutter != null) {
      // Flutter 内置的 dart 用于分析/格式化
      final bundledDart = p.join(
        p.dirname(p.dirname(flutter)),
        'bin',
        'cache',
        'dart-sdk',
        'bin',
      );
      if (Directory(bundledDart).existsSync()) addPath(p.join(bundledDart, 'dart'));
    }
    for (final entry in pathEntries) {
      final existing = env['PATH'] ?? '';
      if (!existing.split(separator).contains(entry)) {
        env['PATH'] = existing.isEmpty ? entry : '$entry$separator$existing';
      }
    }

    if (flutter != null) {
      env['FLUTTER_ROOT'] = p.dirname(p.dirname(flutter));
    }
    if (java != null) {
      env['JAVA_HOME'] = p.dirname(p.dirname(java));
    }
    if (dart != null) {
      env['DART_SDK'] = p.dirname(p.dirname(dart));
    }

    env.putIfAbsent(
      'PUB_CACHE',
      () => p.join(appSupportPath, 'pub-cache'),
    );
    env.putIfAbsent(
      'GRADLE_USER_HOME',
      () => p.join(appSupportPath, 'gradle'),
    );

    final androidSdk = detectAndroidSdk();
    if (androidSdk != null) {
      env['ANDROID_HOME'] ??= androidSdk;
      env['ANDROID_SDK_ROOT'] ??= androidSdk;
    }

    if (useMirror) {
      env['PUB_HOSTED_URL'] ??= 'https://pub.flutter-io.cn';
      env['FLUTTER_STORAGE_BASE_URL'] ??= 'https://storage.flutter-io.cn';
    }

    // 桌面端 Flutter 在 Linux 上需要显式声明运行环境
    if (Platform.isLinux) {
      env.putIfAbsent('XDG_CURRENT_DESKTOP', () => 'KDE');
    }
    return env;
  }

  /// 检测 Android SDK：环境变量优先，其次常见安装位置。
  ///
  /// 只做检测，不自动安装；返回 SDK 根目录或 null。
  static String? detectAndroidSdk() {
    final env = Platform.environment;
    for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final value = env[key];
      if (value != null && _looksLikeSdk(value)) return value;
    }
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    final candidates = <String>[
      if (home.isNotEmpty) p.join(home, 'Android', 'Sdk'),
      if (home.isNotEmpty && Platform.isMacOS)
        p.join(home, 'Library', 'Android', 'sdk'),
      if (Platform.isWindows && (env['LOCALAPPDATA'] ?? '').isNotEmpty)
        p.join(env['LOCALAPPDATA']!, 'Android', 'Sdk'),
    ];
    for (final candidate in candidates) {
      if (_looksLikeSdk(candidate)) return candidate;
    }
    return null;
  }

  static bool _looksLikeSdk(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return false;
    return Directory(p.join(path, 'platform-tools')).existsSync() ||
        Directory(p.join(path, 'cmdline-tools')).existsSync() ||
        _sdkManagerPresent(path);
  }

  static bool _sdkManagerPresent(String sdkRoot) {
    final name = Platform.isWindows ? 'sdkmanager.bat' : 'sdkmanager';
    for (final relative in const [
      'cmdline-tools/latest/bin',
      'cmdline-tools/bin',
      'tools/bin',
    ]) {
      if (File(p.join(sdkRoot, relative, name)).existsSync()) return true;
    }
    return false;
  }

  /// 系统 PATH 中是否存在指定可执行文件
  static bool hasOnPath(String executable) {
    final path = Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final exts = Platform.isWindows
        ? const ['exe', 'bat', 'cmd', '']
        : const [''];
    for (final dir in path.split(separator)) {
      if (dir.trim().isEmpty) continue;
      for (final ext in exts) {
        final name = ext.isEmpty ? executable : '$executable.$ext';
        if (File(p.join(dir, name)).existsSync()) return true;
      }
    }
    return false;
  }

  /// 是否检测到 C++ 编译器
  static bool hasCppCompiler() =>
      const ['g++', 'gcc', 'clang++', 'clang', 'cl'].any(hasOnPath);

  /// 项目可选的 C++ 编译器（仅返回本机可用的）
  static List<String> availableCppCompilers() => [
        if (hasOnPath('g++') || hasOnPath('gcc')) 'g++',
        if (hasOnPath('clang++') || hasOnPath('clang')) 'clang++',
        if (Platform.isWindows && hasOnPath('cl')) 'cl',
      ];
}
