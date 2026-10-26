import 'dart:io';

import 'package:path/path.dart' as p;

import 'github_api_service.dart';

/// 项目快照工具：扫描本地项目生成待推送文件列表（用于建仓库后的首次全量推送）
class ProjectSnapshot {
  ProjectSnapshot._();

  /// 单文件大小上限
  static const int maxFileBytes = 5 * 1024 * 1024;

  /// 跳过的目录
  static const Set<String> skipDirs = {
    '.git',
    '.idea',
    '.dart_tool',
    '.gradle',
    'build',
    '.cxx',
    'node_modules',
  };

  /// 跳过的文件
  static const Set<String> skipFiles = {
    '.env',
    'local.properties',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
  };

  /// 视为二进制的扩展名
  static const Set<String> binaryExts = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'icns',
    'jar', 'keystore', 'jks', 'zip', 'gz', 'tar', '7z',
    'so', 'aar', 'dex', 'class', 'bin', 'ttf', 'otf',
    'woff', 'woff2', 'mp3', 'mp4', 'wav', 'apk', 'aab',
  };

  static bool looksBinary(String path) =>
      binaryExts.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// 收集项目下所有应纳入版本管理的文件
  static Future<List<RepoFile>> collect(
    String projectDir, {
    void Function(String path)? onFile,
    int maxFileBytes = 5 * 1024 * 1024,
    void Function(String path)? onSkip,
  }) async {
    final files = <RepoFile>[];
    await _walk(Directory(projectDir), projectDir, files,
        onFile: onFile, onSkip: onSkip, maxFileBytes: maxFileBytes);
    return files;
  }

  static Future<void> _walk(
    Directory dir,
    String root,
    List<RepoFile> out, {
    void Function(String path)? onFile,
    void Function(String path)? onSkip,
    required int maxFileBytes,
  }) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (skipDirs.contains(name)) continue;
        await _walk(entity, root, out,
            onFile: onFile, onSkip: onSkip, maxFileBytes: maxFileBytes);
      } else if (entity is File) {
        if (skipFiles.contains(name)) {
          onSkip?.call(entity.path);
          continue;
        }
        final stat = await entity.stat();
        if (stat.size > maxFileBytes) {
          onSkip?.call(entity.path);
          continue;
        }
        final relative =
            p.relative(entity.path, from: root).replaceAll(Platform.pathSeparator, '/');
        out.add(RepoFile(
          relative,
          await entity.readAsBytes(),
          isText: !looksBinary(relative),
        ));
        onFile?.call(entity.path);
      }
    }
  }
}
