import 'package:flutter/material.dart';

import '../services/github_actions_templates.dart';
import 'project_payload.dart';

/// 标准载荷：Flutter
class FlutterPayload extends ProjectPayload {
  const FlutterPayload();

  @override
  String get id => 'flutter';

  @override
  String get name => '标准（Flutter）';

  @override
  String get description => 'Flutter 跨平台应用 / 包 / 插件';

  @override
  IconData get icon => Icons.flutter_dash;

  @override
  String get projectNameHint => 'my_flutter_app';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'dart';

  @override
  Map<String, String> get languageByExtension => const {
        'dart': 'dart',
        'yaml': 'yaml',
        'yml': 'yaml',
        'json': 'json',
        'xml': 'xml',
        'html': 'xml',
        'md': 'markdown',
        'kt': 'kotlin',
        'java': 'java',
        'gradle': 'kotlin',
        'kts': 'kotlin',
        'properties': 'plaintext',
        'css': 'css',
        'js': 'javascript',
        'ts': 'typescript',
        'sh': 'bash',
      };

  @override
  bool get isFlutter => true;

  @override
  bool get supportsGitee => true;

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('apk-release', 'APK (Release)', '.apk'),
        PayloadBuildType('apk-debug', 'APK (Debug)', '.apk'),
        PayloadBuildType('appbundle-release', 'AppBundle (Release)', '.aab'),
        PayloadBuildType('ios-release', 'iOS (无签名)', '.app'),
      ];

  @override
  String get workflowContent => GitHubActionsTemplates.flutterBuildWorkflow;

  @override
  List<PayloadFile> templateFiles(String template) {
    switch (template) {
      case 'package':
        return const [
          PayloadFile.asset(
            'pubspec.yaml',
            'assets/templates/package/pubspec.yaml.tmpl',
          ),
          PayloadFile.asset(
            'lib/{{PROJECT_NAME}}.dart',
            'assets/templates/package/package.dart.tmpl',
          ),
          PayloadFile.asset(
            'analysis_options.yaml',
            'assets/templates/app/analysis_options.yaml.tmpl',
          ),
          PayloadFile.asset(
            'README.md',
            'assets/templates/package/README.md.tmpl',
          ),
          PayloadFile.asset('.gitignore', 'assets/templates/app/gitignore.tmpl'),
          PayloadFile.asset(
            '.slipecode.json',
            'assets/templates/package/slipecode.json.tmpl',
          ),
        ];
      case 'plugin':
        return const [
          PayloadFile.asset(
            'pubspec.yaml',
            'assets/templates/plugin/pubspec.yaml.tmpl',
          ),
          PayloadFile.asset(
            'lib/{{PROJECT_NAME}}.dart',
            'assets/templates/plugin/plugin.dart.tmpl',
          ),
          PayloadFile.asset(
            'analysis_options.yaml',
            'assets/templates/app/analysis_options.yaml.tmpl',
          ),
          PayloadFile.asset(
            'README.md',
            'assets/templates/plugin/README.md.tmpl',
          ),
          PayloadFile.asset('.gitignore', 'assets/templates/app/gitignore.tmpl'),
          PayloadFile.asset(
            '.slipecode.json',
            'assets/templates/plugin/slipecode.json.tmpl',
          ),
        ];
      default:
        return const [
          PayloadFile.asset(
            'pubspec.yaml',
            'assets/templates/app/pubspec.yaml.tmpl',
          ),
          PayloadFile.asset('lib/main.dart', 'assets/templates/app/main.dart.tmpl'),
          PayloadFile.asset(
            'analysis_options.yaml',
            'assets/templates/app/analysis_options.yaml.tmpl',
          ),
          PayloadFile.asset('README.md', 'assets/templates/app/README.md.tmpl'),
          PayloadFile.asset('.gitignore', 'assets/templates/app/gitignore.tmpl'),
          PayloadFile.asset(
            '.slipecode.json',
            'assets/templates/app/slipecode.json.tmpl',
          ),
        ];
    }
  }
}
