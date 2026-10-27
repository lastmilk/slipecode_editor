import 'package:flutter/material.dart';

import '../services/git_host.dart';

/// 应用偏好设置
class AppSettings {
  final ThemeMode themeMode;

  /// 编辑器字号
  final double editorFontSize;

  /// 编辑后自动保存
  final bool autoSave;

  /// 首页显示随机语句
  final bool showSaying;

  /// 创建项目时默认使用的 Git 平台
  final GitHost defaultGitHost;

  /// 创建项目时默认勾选「创建仓库并推送」
  final bool createRepoOnCreate;

  // ---------------------------------------------------------------------------
  // LLM / AI 助手配置
  // ---------------------------------------------------------------------------

  /// LLM API 基础地址（OpenAI 兼容协议），例如 https://api.openai.com/v1
  final String llmApiBase;

  /// LLM API Key（用户自备，仅存本地）
  final String llmApiKey;

  /// 模型名称，例如 gpt-4o-mini / claude-sonnet / qwen-plus
  final String llmModel;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.editorFontSize = 14,
    this.autoSave = true,
    this.showSaying = true,
    this.defaultGitHost = GitHost.github,
    this.createRepoOnCreate = true,
    this.llmApiBase = '',
    this.llmApiKey = '',
    this.llmModel = 'gpt-4o-mini',
  });

  static const defaults = AppSettings();

  /// 是否已配置 LLM（可用于 AI 助手）
  bool get isLlmConfigured =>
      llmApiBase.isNotEmpty && llmApiKey.isNotEmpty && llmModel.isNotEmpty;

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? editorFontSize,
    bool? autoSave,
    bool? showSaying,
    GitHost? defaultGitHost,
    bool? createRepoOnCreate,
    String? llmApiBase,
    String? llmApiKey,
    String? llmModel,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      autoSave: autoSave ?? this.autoSave,
      showSaying: showSaying ?? this.showSaying,
      defaultGitHost: defaultGitHost ?? this.defaultGitHost,
      createRepoOnCreate: createRepoOnCreate ?? this.createRepoOnCreate,
      llmApiBase: llmApiBase ?? this.llmApiBase,
      llmApiKey: llmApiKey ?? this.llmApiKey,
      llmModel: llmModel ?? this.llmModel,
    );
  }

  Map<String, dynamic> toJson() => {
        'themeMode': switch (themeMode) {
          ThemeMode.system => 'system',
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
        },
        'editorFontSize': editorFontSize,
        'autoSave': autoSave,
        'showSaying': showSaying,
        'defaultGitHost': defaultGitHost.id,
        'createRepoOnCreate': createRepoOnCreate,
        'llmApiBase': llmApiBase,
        'llmApiKey': llmApiKey,
        'llmModel': llmModel,
      };

  factory AppSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final mode = json['themeMode'] as String?;
    return AppSettings(
      themeMode: switch (mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      editorFontSize: (json['editorFontSize'] as num?)?.toDouble() ??
          defaults.editorFontSize,
      autoSave: json['autoSave'] as bool? ?? defaults.autoSave,
      showSaying: json['showSaying'] as bool? ?? defaults.showSaying,
      defaultGitHost:
          GitHost.fromId(json['defaultGitHost'] as String?, fallback: GitHost.github),
      createRepoOnCreate:
          json['createRepoOnCreate'] as bool? ?? defaults.createRepoOnCreate,
      llmApiBase: json['llmApiBase'] as String? ?? defaults.llmApiBase,
      llmApiKey: json['llmApiKey'] as String? ?? defaults.llmApiKey,
      llmModel: json['llmModel'] as String? ?? defaults.llmModel,
    );
  }
}
