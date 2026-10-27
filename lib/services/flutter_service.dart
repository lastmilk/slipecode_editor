import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// 本地模板项目创建服务
///
/// 设备上没有 Flutter SDK（本机不执行任何 flutter 命令），
/// 创建项目 = 复制内置模板文件并替换占位符。
/// Android 平台工程在首次 GitHub Actions 构建时由 `flutter create` 生成。
class FlutterService {
  /// 模板清单：asset 路径 → 项目内相对路径
  ///
  /// 相对路径中同样支持 {{PROJECT_NAME}} 占位符（用于 `lib/<name>.dart`）。
  static const Map<String, Map<String, String>> _templates = {
    'app': {
      'assets/templates/app/pubspec.yaml.tmpl': 'pubspec.yaml',
      'assets/templates/app/main.dart.tmpl': 'lib/main.dart',
      'assets/templates/app/analysis_options.yaml.tmpl': 'analysis_options.yaml',
      'assets/templates/app/README.md.tmpl': 'README.md',
      'assets/templates/app/gitignore.tmpl': '.gitignore',
      'assets/templates/app/slipecode.json.tmpl': '.slipecode.json',
    },
    'package': {
      'assets/templates/package/pubspec.yaml.tmpl': 'pubspec.yaml',
      'assets/templates/package/package.dart.tmpl': 'lib/{{PROJECT_NAME}}.dart',
      'assets/templates/app/analysis_options.yaml.tmpl': 'analysis_options.yaml',
      'assets/templates/package/README.md.tmpl': 'README.md',
      'assets/templates/app/gitignore.tmpl': '.gitignore',
      'assets/templates/package/slipecode.json.tmpl': '.slipecode.json',
    },
    'plugin': {
      'assets/templates/plugin/pubspec.yaml.tmpl': 'pubspec.yaml',
      'assets/templates/plugin/plugin.dart.tmpl': 'lib/{{PROJECT_NAME}}.dart',
      'assets/templates/app/analysis_options.yaml.tmpl': 'analysis_options.yaml',
      'assets/templates/plugin/README.md.tmpl': 'README.md',
      'assets/templates/app/gitignore.tmpl': '.gitignore',
      'assets/templates/plugin/slipecode.json.tmpl': '.slipecode.json',
    },
  };

  /// 可用的模板类型
  static Iterable<String> get availableTemplates => _templates.keys;

  /// 创建 Flutter 项目（本地模板方式）
  ///
  /// [projectName] 项目名称（snake_case）
  /// [targetPath] 项目将创建在哪个目录下
  /// [org] Android/iOS 的包名前缀
  /// [template] 模板类型：app, package, plugin
  Stream<String> createProject({
    required String projectName,
    required String targetPath,
    String org = 'com.example',
    String template = 'app',
  }) async* {
    final files = _templates[template];
    if (files == null) {
      throw ArgumentError('未知模板类型: $template（可用：${_templates.keys.join(', ')}）');
    }

    yield '> 使用本地模板创建项目（构建将在 GitHub Actions 云端进行）\n';
    yield '  项目: $projectName\n  位置: $targetPath\n  模板: $template\n';

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
      '{{CLASS_NAME}}': _pascalCase(projectName),
      '{{TEMPLATE}}': template,
    };

    for (final entry in files.entries) {
      var content = await rootBundle.loadString(entry.key);
      var relativePath = entry.value;
      for (final token in replacements.entries) {
        content = content.replaceAll(token.key, token.value);
        relativePath = relativePath.replaceAll(token.key, token.value);
      }

      final outPath = p.join(targetPath, relativePath);
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsString(content, flush: true);
      yield '  + $relativePath\n';
    }

    yield '\n✓ 模板文件生成完成（共 ${files.length} 个文件）\n';
    yield '提示：推送到 GitHub 后，Actions 会自动生成 Android 工程并构建 APK。\n';
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
