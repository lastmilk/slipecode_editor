import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/github_actions_templates.dart';
import '../project_payload.dart';
import 'loader_payload.dart';

/// Loader 项目载荷（新 Payload 体系与传统 ProjectPayload 体系的适配层）
///
/// Loader 项目本身不直接提供模板文件 —— 骨架由
/// `LoaderProjectService` 依据 Root/System/Block 三层 Payload 生成。
/// 本类只负责：`.slipe.json` 识别、语法高亮、云端构建类型与 workflow。
class LoaderProjectPayload extends ProjectPayload {
  static const String payloadId = 'loader';

  /// Root Payload 的构建环境（flutter / node）
  final String buildEnv;

  const LoaderProjectPayload({this.buildEnv = 'flutter'});

  /// 读取项目内 loader.json，按 Root Payload 推断构建环境
  static Future<LoaderProjectPayload> detectFrom(String projectDir) async {
    try {
      final file = File(p.join(projectDir, 'loader.json'));
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map && data['root'] is Map) {
          final rootId = (data['root'] as Map)['id'] as String?;
          return LoaderProjectPayload(
            buildEnv: RootPayloadRegistry.byId(rootId).buildEnv,
          );
        }
      }
    } catch (_) {}
    return const LoaderProjectPayload();
  }

  @override
  String get id => payloadId;

  @override
  String get name => 'Loader（三层 Payload）';

  @override
  String get description => 'Root + System + Block 组装的多端项目';

  @override
  IconData get icon => Icons.widgets_outlined;

  @override
  String get projectNameHint => 'my_loader_project';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'plaintext';

  @override
  Map<String, String> get languageByExtension => const {
        'dart': 'dart',
        'yaml': 'yaml',
        'yml': 'yaml',
        'json': 'json',
        'md': 'markdown',
        'html': 'xml',
        'xml': 'xml',
        'css': 'css',
        'js': 'javascript',
        'ts': 'typescript',
        'vue': 'xml',
        'kt': 'kotlin',
        'java': 'java',
        'sh': 'bash',
        'properties': 'plaintext',
      };

  @override
  bool get supportsGitee => true;

  /// Loader 项目只能通过设计稿 / 手动组装创建
  @override
  bool get hiddenFromCreate => true;

  @override
  List<PayloadBuildType> get buildTypes => buildEnv == 'node'
      ? const [PayloadBuildType('release', '构建产物', '.zip')]
      : const [
          PayloadBuildType('apk-release', 'APK (Release)', '.apk'),
          PayloadBuildType('apk-debug', 'APK (Debug)', '.apk'),
          PayloadBuildType('appbundle-release', 'AppBundle (Release)', '.aab'),
        ];

  @override
  String get workflowContent => buildEnv == 'node'
      ? kLoaderNodeWorkflow
      : GitHubActionsTemplates.flutterBuildWorkflow;

  /// Loader 项目的骨架由 LoaderProjectService 生成，不走传统模板
  @override
  List<PayloadFile> templateFiles(String template) => const [];
}
