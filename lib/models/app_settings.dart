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

  // ---------------------------------------------------------------------------
  // 主题背景图片
  // ---------------------------------------------------------------------------

  /// 背景图片显示范围：全局（所有页面）
  static const String backgroundScopeGlobal = 'global';

  /// 背景图片显示范围：仅 IDE 编辑器界面
  static const String backgroundScopeIdeOnly = 'ideOnly';

  /// 背景图片持久化路径（空字符串表示未设置）
  final String backgroundImagePath;

  /// 背景图片显示范围（[backgroundScopeGlobal] / [backgroundScopeIdeOnly]）
  final String backgroundImageScope;

  /// 背景图片不透明度（0.0–1.0，默认 0.15，避免影响前景可读性）
  final double backgroundImageOpacity;

  // ---------------------------------------------------------------------------
  // AI 悬浮球 / 系统悬浮窗
  // ---------------------------------------------------------------------------

  /// 是否在 IDE 右下角显示应用内 AI 悬浮球
  final bool aiFloatingBallEnabled;

  /// 是否启用系统级悬浮球（Android，需要悬浮窗权限；iOS 不支持）
  final bool systemOverlayEnabled;

  // ---------------------------------------------------------------------------
  // 代码补全 / 音量键
  // ---------------------------------------------------------------------------

  /// 是否启用代码补全建议
  final bool completionEnabled;

  /// 是否允许「音量上键 = Tab / 接受补全」。
  ///
  /// 关闭后音量上键仅在补全建议弹出时才接受补全，
  /// 其余时候恢复为正常的音量调节。
  final bool volumeKeyCompletionEnabled;

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
    this.backgroundImagePath = '',
    this.backgroundImageScope = backgroundScopeGlobal,
    this.backgroundImageOpacity = 0.15,
    this.aiFloatingBallEnabled = true,
    this.systemOverlayEnabled = false,
    this.completionEnabled = true,
    this.volumeKeyCompletionEnabled = true,
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
    String? backgroundImagePath,
    String? backgroundImageScope,
    double? backgroundImageOpacity,
    bool? aiFloatingBallEnabled,
    bool? systemOverlayEnabled,
    bool? completionEnabled,
    bool? volumeKeyCompletionEnabled,
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
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      backgroundImageScope: backgroundImageScope ?? this.backgroundImageScope,
      backgroundImageOpacity:
          backgroundImageOpacity ?? this.backgroundImageOpacity,
      aiFloatingBallEnabled:
          aiFloatingBallEnabled ?? this.aiFloatingBallEnabled,
      systemOverlayEnabled: systemOverlayEnabled ?? this.systemOverlayEnabled,
      completionEnabled: completionEnabled ?? this.completionEnabled,
      volumeKeyCompletionEnabled:
          volumeKeyCompletionEnabled ?? this.volumeKeyCompletionEnabled,
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
        'backgroundImagePath': backgroundImagePath,
        'backgroundImageScope': backgroundImageScope,
        'backgroundImageOpacity': backgroundImageOpacity,
        'aiFloatingBallEnabled': aiFloatingBallEnabled,
        'systemOverlayEnabled': systemOverlayEnabled,
        'completionEnabled': completionEnabled,
        'volumeKeyCompletionEnabled': volumeKeyCompletionEnabled,
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
      backgroundImagePath:
          json['backgroundImagePath'] as String? ?? defaults.backgroundImagePath,
      backgroundImageScope: switch (json['backgroundImageScope'] as String?) {
        backgroundScopeIdeOnly => backgroundScopeIdeOnly,
        _ => defaults.backgroundImageScope,
      },
      backgroundImageOpacity:
          (json['backgroundImageOpacity'] as num?)?.toDouble() ??
              defaults.backgroundImageOpacity,
      aiFloatingBallEnabled: json['aiFloatingBallEnabled'] as bool? ??
          defaults.aiFloatingBallEnabled,
      systemOverlayEnabled:
          json['systemOverlayEnabled'] as bool? ?? defaults.systemOverlayEnabled,
      completionEnabled:
          json['completionEnabled'] as bool? ?? defaults.completionEnabled,
      volumeKeyCompletionEnabled: json['volumeKeyCompletionEnabled'] as bool? ??
          defaults.volumeKeyCompletionEnabled,
    );
  }
}
