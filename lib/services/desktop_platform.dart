import 'dart:io';

import 'package:flutter/foundation.dart';

/// 桌面平台能力判定与系统集成小工具。
///
/// 所有桌面专属逻辑都应先经过这里的判定，避免移动端进入未知分支。
class DesktopPlatform {
  DesktopPlatform._();

  /// 是否运行在桌面平台（Windows / macOS / Linux）。
  static bool get isDesktop =>
      !kIsWeb &&
      (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  /// 是否运行在移动平台（Android / iOS）。
  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 宿主操作系统标识：windows / macos / linux / android / ios。
  static String get hostOs {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// 桌面宿主展示名（构建目标过滤用）。
  static String get hostLabel => switch (hostOs) {
        'windows' => 'Windows',
        'macos' => 'macOS',
        'linux' => 'Linux',
        _ => hostOs,
      };

  /// 默认 Shell 可执行文件。
  static String get defaultShell {
    if (Platform.isWindows) {
      final env = Platform.environment;
      // Windows 10/11 默认自带 PowerShell；找不到时退回 cmd。
      if (env['COMSPEC'] != null) return 'powershell.exe';
      return 'cmd.exe';
    }
    final envShell = Platform.environment['SHELL'];
    if (envShell != null && envShell.trim().isNotEmpty) return envShell;
    return Platform.isMacOS ? '/bin/zsh' : '/bin/bash';
  }

  /// 默认 Shell 启动参数（登录 Shell 以加载用户 PATH）。
  static List<String> get defaultShellArgs {
    final shell = defaultShell.toLowerCase();
    if (shell.contains('powershell') || shell.endsWith('pwsh.exe')) {
      return const ['-NoLogo'];
    }
    if (shell.endsWith('cmd.exe')) return const [];
    return const ['-l'];
  }

  /// 当前系统上可用的等宽字体候选（Flutter 会按顺序回退）。
  static String get osMonospaceFont {
    if (Platform.isWindows) return 'Cascadia Mono';
    if (Platform.isMacOS) return 'Menlo';
    return 'DejaVu Sans Mono';
  }

  /// 在系统文件管理器中定位并选中路径。
  static Future<void> revealInFileManager(String path) async {
    if (!isDesktop) return;
    try {
      final type = FileSystemEntity.typeSync(path);
      if (Platform.isMacOS) {
        if (type == FileSystemEntityType.directory) {
          await Process.run('open', [path]);
        } else {
          await Process.run('open', ['-R', path]);
        }
      } else if (Platform.isWindows) {
        final target = path.replaceAll('/', r'\');
        await Process.run('explorer.exe', ['/select,', target]);
      } else {
        final dir = type == FileSystemEntityType.directory
            ? path
            : File(path).parent.path;
        await Process.run('xdg-open', [dir]);
      }
    } catch (e) {
      debugPrint('revealInFileManager 失败：$e');
    }
  }

  /// 用系统默认浏览器打开 URL。
  static Future<void> openInBrowser(String url) async {
    if (!isDesktop) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isWindows) {
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      debugPrint('openInBrowser 失败：$e');
    }
  }
}
