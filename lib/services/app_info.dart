import 'dart:io';

/// 应用静态信息（版本号与 pubspec.yaml 保持一致）
class AppInfo {
  AppInfo._();

  static const String hubName = 'SLIPE Hub';
  static const String editorName = 'SLIPE Editor';
  static const String version = '1.0.0';
  static const String buildNumber = '1';

  static String get versionLabel => '$version+$buildNumber';

  /// 系统描述（用于异常报告 / 日志）
  static String get osLabel {
    final version = Platform.operatingSystemVersion.replaceAll('\n', ' ');
    return '${Platform.operatingSystem} $version';
  }

  /// 简短的宿主平台名（linux / windows / macos）
  static String get hostLabel {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'linux';
  }
}
