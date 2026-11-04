import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/github_actions_templates.dart';
import 'android_payload.dart';
import 'flutter_payload.dart';
import 'html_payload.dart';
import 'loader/loader_project_payload.dart';
import 'node_payload.dart';
import 'taro_payload.dart';

/// 模板文件
///
/// 内容可以内联（[PayloadFile.inline]）或来自 asset（[PayloadFile.asset]）。
class PayloadFile {
  /// 项目内相对路径，支持 {{PROJECT_NAME}} 等占位符
  final String path;

  /// 内联内容
  final String? content;

  /// asset 路径
  final String? asset;

  const PayloadFile.inline(this.path, String this.content) : asset = null;

  const PayloadFile.asset(this.path, String this.asset) : content = null;
}

/// Payload 的构建类型（对应 workflow_dispatch 的 build_type 输入）
class PayloadBuildType {
  final String id;
  final String label;
  final String artifactExt;

  const PayloadBuildType(this.id, this.label, this.artifactExt);
}

/// 项目载荷（Payload）
///
/// 决定一个项目使用什么模板代码、如何做语法高亮、使用什么 GitHub Actions。
/// 新增载荷只需实现本类并在 [PayloadRegistry] 中注册，无需改动其它模块。
abstract class ProjectPayload {
  const ProjectPayload();

  /// 唯一标识（写入 .slipe.json 的 payload 字段）
  String get id;

  /// 展示名称
  String get name;

  /// 一句话说明
  String get description;

  /// 图标
  IconData get icon;

  /// 项目名输入提示
  String get projectNameHint;

  /// 默认组织 / 包名前缀
  String get defaultOrg;

  /// 文件扩展名 → 高亮语言
  Map<String, String> get languageByExtension;

  /// 无法识别的扩展名使用的高亮语言
  String get defaultLanguage;

  /// 支持的构建类型
  List<PayloadBuildType> get buildTypes;

  /// 模板文件
  ///
  /// [template] 仅 Flutter 载荷会用到（app / package / plugin），其它载荷忽略。
  List<PayloadFile> templateFiles(String template);

  /// GitHub Actions workflow 内容
  String get workflowContent;

  /// workflow 文件路径
  String get workflowPath => GitHubActionsTemplates.workflowPath;

  /// 是否支持 Gitee Go 构建
  bool get supportsGitee => false;

  /// 是否为 Flutter 项目（用于显示 Flutter 专属功能，如新建 Dart 类）
  bool get isFlutter => false;

  /// 是否在「创建传统项目」页隐藏（如 Loader 载荷只能由设计稿/组装创建）
  bool get hiddenFromCreate => false;

  /// 根据文件路径返回高亮语言
  String languageFor(String filePath) {
    final ext = p.extension(filePath).replaceFirst('.', '').toLowerCase();
    return languageByExtension[ext] ?? defaultLanguage;
  }
}

/// Payload 注册表
///
/// 内置 5 种载荷，可通过 [register] 追加自定义载荷（可插拔、可扩展）。
class PayloadRegistry {
  PayloadRegistry._();

  static final List<ProjectPayload> _payloads = [
    const FlutterPayload(),
    const AndroidPayload(),
    const NodeBackendPayload(),
    const HtmlFrontendPayload(),
    const TaroPayload(),
    // Loader 项目（三层 Payload 体系）不参与创建页选择，
    // 仅用于打开已生成的 Loader 项目时识别。
    const LoaderProjectPayload(),
  ];

  /// 全部已注册载荷
  static List<ProjectPayload> get all => List.unmodifiable(_payloads);

  /// 默认载荷（标准 Flutter）
  static ProjectPayload get fallback => _payloads.first;

  /// 注册（或替换同 id）一个载荷
  static void register(ProjectPayload payload) {
    _payloads.removeWhere((item) => item.id == payload.id);
    _payloads.add(payload);
  }

  /// 按 id 查找，找不到时退回默认载荷
  static ProjectPayload byId(String? id) {
    if (id == null || id.isEmpty) return fallback;
    for (final payload in _payloads) {
      if (payload.id == id) return payload;
    }
    return fallback;
  }

  /// 读取项目内的 `.slipe.json` 并按标记识别载荷
  static Future<ProjectPayload> detect(String projectDir) async {
    try {
      final marker = File(p.join(projectDir, '.slipe.json'));
      if (await marker.exists()) {
        final data = jsonDecode(await marker.readAsString());
        if (data is Map && data['payload'] is String) {
          final id = data['payload'] as String;
          // Loader 项目需进一步读取 loader.json 推断 Root 构建环境
          if (id == LoaderProjectPayload.payloadId) {
            return LoaderProjectPayload.detectFrom(projectDir);
          }
          return byId(id);
        }
      }
      return await _inferFromFiles(projectDir);
    } catch (_) {
      return fallback;
    }
  }

  /// 没有标记文件时按特征文件推断
  static Future<ProjectPayload> _inferFromFiles(String projectDir) async {
    Future<bool> has(String relative) async =>
        File(p.join(projectDir, relative)).existsSync();

    if (await has('pubspec.yaml')) return byId('flutter');
    if (await has('project.config.json') || await has('src/app.tsx')) {
      return byId('taro');
    }
    if (await has('settings.gradle') ||
        await has('settings.gradle.kts') ||
        await has('build.gradle') ||
        await has('build.gradle.kts')) {
      return byId('android');
    }
    if (await has('package.json')) return byId('node');
    if (await has('index.html')) return byId('html');
    return fallback;
  }
}
