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

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.editorFontSize = 14,
    this.autoSave = true,
    this.showSaying = true,
    this.defaultGitHost = GitHost.github,
    this.createRepoOnCreate = true,
  });

  static const defaults = AppSettings();

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? editorFontSize,
    bool? autoSave,
    bool? showSaying,
    GitHost? defaultGitHost,
    bool? createRepoOnCreate,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      autoSave: autoSave ?? this.autoSave,
      showSaying: showSaying ?? this.showSaying,
      defaultGitHost: defaultGitHost ?? this.defaultGitHost,
      createRepoOnCreate: createRepoOnCreate ?? this.createRepoOnCreate,
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
    );
  }
}
