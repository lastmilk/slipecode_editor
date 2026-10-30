import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../payloads/project_payload.dart';

/// 项目创建服务
///
/// 按选定的 [ProjectPayload] 复制内置模板并替换占位符。
/// 设备上不执行任何 flutter / gradle / npm 命令，构建全部在云端完成。
class ProjectCreateService {
  /// 创建项目
  ///
  /// [payload] 决定模板文件、语言与 GitHub Actions
  /// [projectName] 项目名称（snake_case）
  /// [targetPath] 项目将创建在哪个目录下
  /// [org] Android/iOS 的包名前缀
  /// [template] 模板类型（仅 Flutter 载荷使用）
  Stream<String> createProject({
    required ProjectPayload payload,
    required String projectName,
    required String targetPath,
    String org = 'com.example',
    String template = 'app',
  }) async* {
    final files = payload.templateFiles(template);
    if (files.isEmpty) {
      throw ArgumentError('载荷 ${payload.id} 没有定义模板文件');
    }

    yield '> 使用「${payload.name}」载荷创建项目\n';
    yield '  项目: $projectName\n  位置: $targetPath\n  载荷: ${payload.id}\n';

    // 目标目录检查
    final dir = Directory(targetPath);
    if (await dir.exists()) {
      if (!await dir.list(followLinks: false).isEmpty) {
        throw Exception('目标目录已存在且不为空: $targetPath');
      }
    } else {
      await dir.create(recursive: true);
      yield '创建目录: $targetPath\n';
    }

    final replacements = <String, String>{
      '{{PROJECT_NAME}}': projectName,
      '{{ORG}}': org,
      '{{ORG_PATH}}': org.replaceAll('.', '/'),
      '{{CLASS_NAME}}': _pascalCase(projectName),
      '{{TEMPLATE}}': template,
      '{{PAYLOAD}}': payload.id,
      '{{PAYLOAD_NAME}}': payload.name,
    };

    for (final file in files) {
      var content = file.content ?? await rootBundle.loadString(file.asset!);
      var relativePath = file.path;
      for (final token in replacements.entries) {
        content = content.replaceAll(token.key, token.value);
        relativePath = relativePath.replaceAll(token.key, token.value);
      }

      final outFile = File(p.join(targetPath, relativePath));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsString(content, flush: true);
      yield '  + $relativePath\n';
    }

    yield '\n✓ 模板文件生成完成（共 ${files.length} 个文件）\n';
    yield '提示：推送到远程仓库后，Actions 会按「${payload.name}」载荷执行云端构建。\n';
  }

  /// snake_case → PascalCase（如 my_app → MyApp）
  static String _pascalCase(String name) {
    return name
        .split('_')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join();
  }
}
