import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/llm_profile.dart';
import '../services/git_host.dart';

/// 偏好设置状态管理
///
/// 本地使用 SharedPreferences 持久化；登录 SLIPE 账号后，
/// 每次修改会通过 [attachRemoteSync] 注册的回调推送到后端。
class SettingsProvider extends ChangeNotifier {
  static const _key = 'slipe_app_settings';

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
    L10n.apply(_settings.language);
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
  ///
  /// 远端只保存“可跨设备”的配置：
  /// - LLM 的 API Key 未同步时保留本地 Key；
  /// - 头像/壁纸是设备本地路径，始终保留本地值。
  Future<void> applyRemote(Map<String, dynamic>? json) async {
    if (json == null || json.isEmpty) return;
    final remote = AppSettings.fromJson(json);
    final mergedProfiles = remote.llmProfiles.map((profile) {
      if (profile.apiKey.isNotEmpty) return profile;
      final local = _settings.llmProfiles
          .where((item) => item.id == profile.id)
          .firstOrNull;
      return local == null ? profile : profile.copyWith(apiKey: local.apiKey);
    }).toList();
    _settings = remote.copyWith(
      llmProfiles: mergedProfiles,
      backgroundImagePath: _settings.backgroundImagePath,
      avatarPath: _settings.avatarPath,
      // 应用锁属于设备本地安全设置，不跟随云端
      appLockEnabled: _settings.appLockEnabled,
    );
    L10n.apply(_settings.language);
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

  /// 切换界面语言（立即生效，无需重启）
  Future<void> setLanguage(String language) async {
    _settings = _settings.copyWith(language: language);
    L10n.apply(language);
    await _save();
  }

  Future<void> setFontFamily(String fontFamily) async {
    _settings = _settings.copyWith(fontFamily: fontFamily);
    await _save();
  }

  Future<void> setAiApprovalEnabled(bool value) async {
    _settings = _settings.copyWith(aiApprovalEnabled: value);
    await _save();
  }

  Future<void> setAppLockEnabled(bool value) async {
    _settings = _settings.copyWith(appLockEnabled: value);
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

  Future<void> setBuildAutoDownload(bool value) async {
    _settings = _settings.copyWith(buildAutoDownload: value);
    await _save();
  }

  Future<void> setBuildServerRelay(bool value) async {
    _settings = _settings.copyWith(buildServerRelay: value);
    await _save();
  }

  /// 记录用户同意《用户协议》与《隐私政策》
  Future<void> acceptPolicies(String version) async {
    _settings = _settings.copyWith(
      policyAcceptedVersion: version,
      policyAcceptedAt: DateTime.now().toIso8601String(),
    );
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
  // 多模型配置（LLM Profile）
  // ---------------------------------------------------------------------------

  /// 新增或更新一个模型配置
  Future<void> upsertLlmProfile(LlmProfile profile) async {
    final list = List<LlmProfile>.from(_settings.llmProfiles);
    final index = list.indexWhere((item) => item.id == profile.id);
    if (index >= 0) {
      list[index] = profile;
    } else {
      list.add(profile);
    }
    _settings = _settings.copyWith(
      llmProfiles: list,
      activeLlmId: _settings.activeLlmId.isEmpty
          ? profile.id
          : _settings.activeLlmId,
    );
    await _save();
  }

  /// 删除模型配置；删除当前激活项时自动切换到第一个
  Future<void> removeLlmProfile(String id) async {
    final list = _settings.llmProfiles.where((item) => item.id != id).toList();
    var activeId = _settings.activeLlmId;
    if (activeId == id) {
      activeId = list.isEmpty ? '' : list.first.id;
    }
    _settings = _settings.copyWith(llmProfiles: list, activeLlmId: activeId);
    await _save();
  }

  /// 切换当前使用的模型
  Future<void> setActiveLlm(String id) async {
    if (!_settings.llmProfiles.any((item) => item.id == id)) return;
    _settings = _settings.copyWith(activeLlmId: id, llmUseBuiltin: false);
    await _save();
  }

  /// 切换使用 SLIPE 内置模型
  Future<void> setUseBuiltinLlm(bool value) async {
    _settings = _settings.copyWith(llmUseBuiltin: value);
    await _save();
  }

  /// 选择某个内置模型（自动切换到内置模型模式）
  Future<void> setBuiltinLlm(String id) async {
    _settings = _settings.copyWith(
      llmUseBuiltin: true,
      builtinLlmId: id,
    );
    await _save();
  }

  /// 是否把模型配置（含 API Key）同步到云端
  Future<void> setLlmCloudSync(bool value) async {
    _settings = _settings.copyWith(llmCloudSync: value);
    await _save();
  }

  /// 是否把 AI 对话记录同步到云端
  Future<void> setChatCloudSync(bool value) async {
    _settings = _settings.copyWith(chatCloudSync: value);
    await _save();
  }

  /// 是否启用任务实况通知（类灵动岛）
  Future<void> setLiveNotifications(bool value) async {
    _settings = _settings.copyWith(liveNotifications: value);
    await _save();
  }

  /// 是否启用 GitHub 专用 Hosts
  Future<void> setGithubHostsEnabled(bool value) async {
    _settings = _settings.copyWith(githubHostsEnabled: value);
    await _save();
  }

  /// 云同步网络策略：wifi / any / never
  Future<void> setSyncNetwork(String policy) async {
    _settings = _settings.copyWith(syncNetwork: policy);
    await _save();
  }

  /// 应用从云端下载的头像（本地文件路径）
  Future<void> applyServerAvatarPath(String path) async {
    _settings = _settings.copyWith(avatarPath: path);
    await _persist();
    notifyListeners();
  }

  /// 应用从云端下载的壁纸（本地文件路径 + 云端版本号）
  Future<void> applyServerWallpaperPath(String path, String version) async {
    _settings = _settings.copyWith(
      backgroundImagePath: path,
      wallpaperCloudVersion: version,
    );
    await _persist();
    notifyListeners();
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
  // 首页个性化（标题 / 头像）
  // ---------------------------------------------------------------------------

  Future<void> setHomeTitle(String value) async {
    final title = value.trim();
    _settings = _settings.copyWith(homeTitle: title.isEmpty ? 'SLIPE' : title);
    await _save();
  }

  /// 设置首页自定义文案库（一行一条，空行自动过滤）
  Future<void> setHomeCustomTexts(List<String> texts) async {
    final cleaned = [
      for (final line in texts)
        if (line.trim().isNotEmpty) line.trim(),
    ];
    _settings = _settings.copyWith(homeCustomTexts: cleaned);
    await _save();
  }

  /// 首页文案是否混入一言源（开启后一言/自定义各 50% 概率）
  Future<void> setHomeSayingSourceEnabled(bool value) async {
    _settings = _settings.copyWith(homeSayingSourceEnabled: value);
    await _save();
  }

  Future<void> setAvatarPath(String path) async {
    _settings = _settings.copyWith(avatarPath: path);
    await _save();
  }

  Future<void> clearAvatar() async {
    _settings = _settings.copyWith(avatarPath: '');
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
      unawaited(sync(_settings.toJson(includeSecrets: _settings.llmCloudSync)));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_settings.toJson()));
  }
}
