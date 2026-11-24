import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'local_build_models.dart';

/// 构建产物定位：按目标扫描常见输出目录。
class ArtifactResolver {
  const ArtifactResolver();

  Future<List<LocalArtifact>> resolve({
    required String projectPath,
    required LocalBuildTarget target,
  }) async {
    final patterns = _patternsFor(target);
    final result = <LocalArtifact>[];
    final seen = <String>{};
    for (final pattern in patterns) {
      final matches = await _glob(projectPath, pattern);
      for (final path in matches) {
        if (!seen.add(path)) continue;
        final artifact = await _describe(path);
        if (artifact != null) result.add(artifact);
      }
    }
    // 新产物优先
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result.take(12).toList();
  }

  /// 简单通配：支持 `dir/**/*.ext`、`dir` 与 `dir/*.ext`
  List<String> _patternsFor(LocalBuildTarget target) {
    if (target.id == 'custom.script') return const [];
    switch (target.payloadId) {
      case 'flutter':
        switch (target.flutterTarget) {
          case 'apk':
          case 'appbundle':
            return const [
              'build/app/outputs/**/*.apk',
              'build/app/outputs/**/*.aab',
            ];
          case 'web':
            return const ['build/web'];
          case 'linux':
            return const ['build/linux/**/release/bundle', 'build/linux/**/*.AppImage'];
          case 'windows':
            return const ['build/windows/**/Release'];
          case 'macos':
            return const ['build/macos/**/Release/*.app'];
          case 'ios':
            return const ['build/ios/**/*.app'];
        }
        return const ['build'];
      case 'node':
      case 'taro':
        return const ['dist', 'build', 'out'];
      case 'android':
        return const ['app/build/outputs/**/*.apk'];
      case 'html':
        return const ['.'];
      default:
        return const [];
    }
  }

  Future<List<String>> _glob(String root, String pattern) async {
    final normalized = pattern.replaceAll('\\', '/');
    final segments = normalized.split('/');
    var current = [root];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;
      final next = <String>[];
      if (segment == '.') {
        next.addAll(current);
      } else if (segment == '**') {
        for (final dir in current) {
          next.add(dir);
          // 递归展开（限制深度与目录数量，避免扫描整棵大目录）
          var frontier = <String>[dir];
          var scanned = 0;
          var depth = 0;
          while (frontier.isNotEmpty && depth < 6 && scanned < 1500) {
            final nextFrontier = <String>[];
            for (final item in frontier) {
              try {
                await for (final entity
                    in Directory(item).list(followLinks: false)) {
                  if (entity is Directory) {
                    nextFrontier.add(entity.path);
                    scanned++;
                  }
                }
              } catch (e) {
                debugPrint('扫描产物目录失败：$e');
              }
            }
            next.addAll(nextFrontier);
            frontier = nextFrontier;
            depth++;
          }
        }
      } else if (segment.contains('*')) {
        final regex = RegExp(
          '^${segment.replaceAll('.', r'\.').replaceAll('*', '.*')}\$',
        );
        for (final dir in current) {
          final directory = Directory(dir);
          if (!await directory.exists()) continue;
          try {
            await for (final entity in directory.list(followLinks: false)) {
              final name = p.basename(entity.path);
              if (!regex.hasMatch(name)) continue;
              if (isLast) {
                next.add(entity.path);
              } else if (entity is Directory) {
                next.add(entity.path);
              }
            }
          } catch (e) {
            debugPrint('扫描产物失败：$e');
          }
        }
      } else {
        for (final dir in current) {
          final candidate = p.join(dir, segment);
          if (isLast) {
            if (FileSystemEntity.typeSync(candidate) !=
                FileSystemEntityType.notFound) {
              next.add(candidate);
            }
          } else {
            if (Directory(candidate).existsSync()) next.add(candidate);
          }
        }
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  Future<LocalArtifact?> _describe(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(path);
        var size = 0;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              size += await entity.length();
            } catch (_) {
              // 忽略
            }
          }
        }
        return LocalArtifact(
          path: path,
          sizeBytes: size,
          modifiedAt: dir.statSync().modified,
        );
      }
      final file = File(path);
      final stat = await file.stat();
      return LocalArtifact(
        path: path,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      );
    } catch (e) {
      debugPrint('读取产物信息失败（$path）：$e');
      return null;
    }
  }

  /// 自定义脚本的产物路径：`.slipe.json` 的 `artifactPath`。
  Future<String?> customArtifactPath(String projectPath) async {
    final file = File(p.join(projectPath, '.slipe.json'));
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return null;
      final value = data['artifactPath'];
      if (value is! String || value.trim().isEmpty) return null;
      return p.isAbsolute(value) ? value : p.join(projectPath, value);
    } catch (_) {
      return null;
    }
  }
}
