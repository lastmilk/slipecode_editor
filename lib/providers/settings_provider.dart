import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../services/git_host.dart';

/// 偏好设置状态管理
///
/// 本地使用 SharedPreferences 持久化；登录 SlipCode 账号后，
/// 每次修改会通过 [attachRemoteSync] 注册的回调推送到后端。
class SettingsProvider extends ChangeNotifier {
  static const _key = 'slipecode_app_settings';

  AppSettings _settings = AppSettings.defaults;
  AppSettings get settings => _settings;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> Function(Map<String, dynamic> json)? _remoteSync;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        _settings = AppSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        _settings = AppSettings.defaults;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 注册远程同步回调（账号登录后由 main 注入）
  void attachRemoteSync(
    Future<void> Function(Map<String, dynamic> json)? callback,
  ) {
    _remoteSync = callback;
  }

  /// 应用云端设置（不触发再次上传）
  Future<void> applyRemote(Map<String, dynamic>? json) async {
    if (json == null || json.isEmpty) return;
    _settings = AppSettings.fromJson(json);
    await _persist();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _settings = _settings.copyWith(themeMode: mode);
    await _save();
  }

  Future<void> setEditorFontSize(double size) async {
    _settings = _settings.copyWith(
      editorFontSize: size.clamp(11.0, 22.0).toDouble(),
    );
    await _save();
  }

  Future<void> setAutoSave(bool value) async {
    _settings = _settings.copyWith(autoSave: value);
    await _save();
  }

  Future<void> setShowSaying(bool value) async {
    _settings = _settings.copyWith(showSaying: value);
    await _save();
  }

  Future<void> setDefaultGitHost(GitHost host) async {
    _settings = _settings.copyWith(defaultGitHost: host);
    await _save();
  }

  Future<void> setCreateRepoOnCreate(bool value) async {
    _settings = _settings.copyWith(createRepoOnCreate: value);
    await _save();
  }

  // ---------------------------------------------------------------------------
  // LLM / AI 助手
  // ---------------------------------------------------------------------------

  Future<void> setLlmApiBase(String value) async {
    _settings = _settings.copyWith(llmApiBase: value.trim());
    await _save();
  }

  Future<void> setLlmApiKey(String value) async {
    _settings = _settings.copyWith(llmApiKey: value.trim());
    await _save();
  }

  Future<void> setLlmModel(String value) async {
    _settings = _settings.copyWith(llmModel: value.trim());
    await _save();
  }

  // ---------------------------------------------------------------------------
  // AI 悬浮球 / 系统悬浮窗
  // ---------------------------------------------------------------------------

  Future<void> setAiFloatingBallEnabled(bool value) async {
    _settings = _settings.copyWith(aiFloatingBallEnabled: value);
    await _save();
  }

  Future<void> setSystemOverlayEnabled(bool value) async {
    _settings = _settings.copyWith(systemOverlayEnabled: value);
    await _save();
  }

  // ---------------------------------------------------------------------------
  // 代码补全 / 音量键
  // ---------------------------------------------------------------------------

  Future<void> setCompletionEnabled(bool value) async {
    _settings = _settings.copyWith(completionEnabled: value);
    await _save();
  }

  Future<void> setVolumeKeyCompletionEnabled(bool value) async {
    _settings = _settings.copyWith(volumeKeyCompletionEnabled: value);
    await _save();
  }

  // ---------------------------------------------------------------------------
  // 主题背景图片
  // ---------------------------------------------------------------------------

  /// 设置背景图片（传入已复制到应用文档目录的持久化路径）
  Future<void> setBackgroundImage(String path) async {
    _settings = _settings.copyWith(backgroundImagePath: path);
    await _save();
  }

  /// 设置背景图片显示范围（AppSettings.backgroundScopeGlobal / backgroundScopeIdeOnly）
  Future<void> setBackgroundScope(String scope) async {
    _settings = _settings.copyWith(backgroundImageScope: scope);
    await _save();
  }

  /// 设置背景图片不透明度（0.0–1.0）
  Future<void> setBackgroundOpacity(double value) async {
    _settings = _settings.copyWith(
      backgroundImageOpacity: value.clamp(0.0, 1.0).toDouble(),
    );
    await _save();
  }

  /// 清除背景图片，恢复默认
  Future<void> clearBackgroundImage() async {
    _settings = _settings.copyWith(backgroundImagePath: '');
    await _save();
  }

  Future<void> _save() async {
    await _persist();
    notifyListeners();
    final sync = _remoteSync;
    if (sync != null) {
      // 失败不影响本地设置，账号页会显示同步状态
      unawaited(sync(_settings.toJson()));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_settings.toJson()));
  }
}
