import 'package:flutter/material.dart';

import '../services/git_host.dart';
import 'llm_profile.dart';

/// 可选的常见字体
class AppFontOption {
  final String id;
  final String label;
  const AppFontOption(this.id, this.label);
}

const List<AppFontOption> appFontOptions = [
  AppFontOption('', '系统默认'),
  AppFontOption('sans-serif', '无衬线'),
  AppFontOption('serif', '衬线'),
  AppFontOption('monospace', '等宽'),
  AppFontOption('Roboto', 'Roboto'),
  AppFontOption('Noto Sans SC', 'Noto Sans SC（思源黑体）'),
  AppFontOption('Source Han Serif', '思源宋体'),
];

/// 应用偏好设置
class AppSettings {
  final ThemeMode themeMode;

  /// 编辑器字号
  final double editorFontSize;

  /// 界面语言：zh（简体）/ zhHant（繁体）/ en（英文）
  final String language;

  /// 应用字体族（空字符串表示系统默认）
  final String fontFamily;

  /// AI 改动写盘前是否需要用户审批
  final bool aiApprovalEnabled;

  /// Agent 操作审批模式：manual / auto / full / custom
  final String agentApprovalMode;

  /// 自定义审批规则（一行一条：allow <工具或命令前缀> / deny <…> / ask <…>）
  final String agentApprovalRules;

  /// 是否开启应用锁（生物认证 + 密码兜底）
  final bool appLockEnabled;

  /// 首页显示随机语句
  final bool showSaying;

  /// 创建项目时默认使用的 Git 平台
  final GitHost defaultGitHost;

  /// 创建项目时默认勾选「创建仓库并推送」
  final bool createRepoOnCreate;

  /// 云端构建完成后自动下载构建产物到本地
  final bool buildAutoDownload;

  /// 登录用户构建产物先由服务端中转下载（缓解国内访问 GitHub 的网络问题）
  final bool buildServerRelay;

  /// 已同意的《用户协议》与《隐私政策》版本号（空表示未同意 → 受限模式）
  final String policyAcceptedVersion;

  /// 上次同意政策的时间戳（ISO 8601，未同意为空）
  final String policyAcceptedAt;

  // ---------------------------------------------------------------------------
  // LLM / AI 助手配置
  // ---------------------------------------------------------------------------

  /// LLM API 基础地址（OpenAI 兼容协议），例如 https://api.openai.com/v1
  final String llmApiBase;

  /// LLM API Key（用户自备，仅存本地）
  final String llmApiKey;

  /// 模型名称，例如 gpt-4o-mini / claude-sonnet / qwen-plus
  ///
  /// 仅用于兼容旧版本；新代码请使用 [llmProfiles] / [activeLlm]。
  final String llmModel;

  /// 多模型配置（Provider Profile）
  final List<LlmProfile> llmProfiles;

  /// 当前激活的模型 id
  final String activeLlmId;

  /// 是否使用 SLIPE 内置模型（登录后可用，默认开启）
  final bool llmUseBuiltin;

  /// 当前选择的内置模型 id（为空时使用后端下发的默认模型）
  final String builtinLlmId;

  /// 是否把模型配置（含 API Key）同步到云端
  final bool llmCloudSync;

  /// 是否把 AI 对话记录同步到云端
  final bool chatCloudSync;

  /// 云同步网络策略：wifi / any / never
  final String syncNetwork;

  /// 云端壁纸版本号（用于判断是否需要重新下载）
  final String wallpaperCloudVersion;

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

  /// 是否启用任务实况通知（类灵动岛：AI 执行 / 云端构建进度）
  final bool liveNotifications;

  /// 是否启用 GitHub 专用 Hosts（仅应用内 HTTP 请求，不涉及 VPN / 代理）
  final bool githubHostsEnabled;

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

  // ---------------------------------------------------------------------------
  // 首页个性化
  // ---------------------------------------------------------------------------

  /// 首页标题文案（默认 SLIPE）
  final String homeTitle;

  /// 用户头像图片路径（空字符串表示使用默认头像）
  final String avatarPath;

  /// 首页自定义文案库（一行一条）
  final List<String> homeCustomTexts;

  /// 首页文案是否同时混入一言源（开启后各 50% 概率；关闭则纯自定义）
  final bool homeSayingSourceEnabled;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.editorFontSize = 14,
    this.language = 'zh',
    this.fontFamily = '',
    this.aiApprovalEnabled = true,
    this.agentApprovalMode = 'auto',
    this.agentApprovalRules = '',
    this.appLockEnabled = false,
    this.showSaying = true,
    this.defaultGitHost = GitHost.github,
    this.createRepoOnCreate = true,
    this.buildAutoDownload = true,
    this.buildServerRelay = true,
    this.policyAcceptedVersion = '',
    this.policyAcceptedAt = '',
    this.llmApiBase = '',
    this.llmApiKey = '',
    this.llmModel = 'gpt-4o-mini',
    this.llmProfiles = const [],
    this.activeLlmId = '',
    this.llmUseBuiltin = true,
    this.builtinLlmId = '',
    this.llmCloudSync = false,
    this.chatCloudSync = false,
    this.syncNetwork = 'wifi',
    this.wallpaperCloudVersion = '',
    this.backgroundImagePath = '',
    this.backgroundImageScope = backgroundScopeGlobal,
    this.backgroundImageOpacity = 0.15,
    this.aiFloatingBallEnabled = true,
    this.systemOverlayEnabled = false,
    this.liveNotifications = true,
    this.githubHostsEnabled = true,
    this.completionEnabled = true,
    this.volumeKeyCompletionEnabled = true,
    this.homeTitle = 'SLIPE',
    this.avatarPath = '',
    this.homeCustomTexts = const [],
    this.homeSayingSourceEnabled = true,
  });

  static const defaults = AppSettings();

  /// 是否已配置 LLM（可用于 AI 助手）
  bool get isLlmConfigured => activeLlm?.isConfigured ?? false;

  /// 当前激活的模型配置
  LlmProfile? get activeLlm {
    if (llmProfiles.isEmpty) return null;
    for (final profile in llmProfiles) {
      if (profile.id == activeLlmId) return profile;
    }
    return llmProfiles.first;
  }

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? editorFontSize,
    String? language,
    String? fontFamily,
    bool? aiApprovalEnabled,
    String? agentApprovalMode,
    String? agentApprovalRules,
    bool? appLockEnabled,
    bool? showSaying,
    GitHost? defaultGitHost,
    bool? createRepoOnCreate,
    bool? buildAutoDownload,
    bool? buildServerRelay,
    String? policyAcceptedVersion,
    String? policyAcceptedAt,
    String? llmApiBase,
    String? llmApiKey,
    String? llmModel,
    List<LlmProfile>? llmProfiles,
    String? activeLlmId,
    bool? llmUseBuiltin,
    String? builtinLlmId,
    bool? llmCloudSync,
    bool? chatCloudSync,
    String? syncNetwork,
    String? wallpaperCloudVersion,
    String? backgroundImagePath,
    String? backgroundImageScope,
    double? backgroundImageOpacity,
    bool? aiFloatingBallEnabled,
    bool? systemOverlayEnabled,
    bool? liveNotifications,
    bool? githubHostsEnabled,
    bool? completionEnabled,
    bool? volumeKeyCompletionEnabled,
    String? homeTitle,
    String? avatarPath,
    List<String>? homeCustomTexts,
    bool? homeSayingSourceEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      language: language ?? this.language,
      fontFamily: fontFamily ?? this.fontFamily,
      aiApprovalEnabled: aiApprovalEnabled ?? this.aiApprovalEnabled,
      agentApprovalMode: agentApprovalMode ?? this.agentApprovalMode,
      agentApprovalRules: agentApprovalRules ?? this.agentApprovalRules,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      showSaying: showSaying ?? this.showSaying,
      defaultGitHost: defaultGitHost ?? this.defaultGitHost,
      createRepoOnCreate: createRepoOnCreate ?? this.createRepoOnCreate,
      buildAutoDownload: buildAutoDownload ?? this.buildAutoDownload,
      buildServerRelay: buildServerRelay ?? this.buildServerRelay,
      policyAcceptedVersion:
          policyAcceptedVersion ?? this.policyAcceptedVersion,
      policyAcceptedAt: policyAcceptedAt ?? this.policyAcceptedAt,
      llmApiBase: llmApiBase ?? this.llmApiBase,
      llmApiKey: llmApiKey ?? this.llmApiKey,
      llmModel: llmModel ?? this.llmModel,
      llmProfiles: llmProfiles ?? this.llmProfiles,
      activeLlmId: activeLlmId ?? this.activeLlmId,
      llmUseBuiltin: llmUseBuiltin ?? this.llmUseBuiltin,
      builtinLlmId: builtinLlmId ?? this.builtinLlmId,
      llmCloudSync: llmCloudSync ?? this.llmCloudSync,
      chatCloudSync: chatCloudSync ?? this.chatCloudSync,
      syncNetwork: syncNetwork ?? this.syncNetwork,
      wallpaperCloudVersion:
          wallpaperCloudVersion ?? this.wallpaperCloudVersion,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      backgroundImageScope: backgroundImageScope ?? this.backgroundImageScope,
      backgroundImageOpacity:
          backgroundImageOpacity ?? this.backgroundImageOpacity,
      aiFloatingBallEnabled:
          aiFloatingBallEnabled ?? this.aiFloatingBallEnabled,
      systemOverlayEnabled: systemOverlayEnabled ?? this.systemOverlayEnabled,
      liveNotifications: liveNotifications ?? this.liveNotifications,
      githubHostsEnabled: githubHostsEnabled ?? this.githubHostsEnabled,
      completionEnabled: completionEnabled ?? this.completionEnabled,
      volumeKeyCompletionEnabled:
          volumeKeyCompletionEnabled ?? this.volumeKeyCompletionEnabled,
      homeTitle: homeTitle ?? this.homeTitle,
      avatarPath: avatarPath ?? this.avatarPath,
      homeCustomTexts: homeCustomTexts ?? this.homeCustomTexts,
      homeSayingSourceEnabled:
          homeSayingSourceEnabled ?? this.homeSayingSourceEnabled,
    );
  }

  Map<String, dynamic> toJson({bool includeSecrets = true}) {
    final llm = activeLlm;
    return {
      'themeMode': switch (themeMode) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      },
      'editorFontSize': editorFontSize,
      'language': language,
      'fontFamily': fontFamily,
      'aiApprovalEnabled': aiApprovalEnabled,
      'agentApprovalMode': agentApprovalMode,
      'agentApprovalRules': agentApprovalRules,
      'appLockEnabled': appLockEnabled,
      'showSaying': showSaying,
      'defaultGitHost': defaultGitHost.id,
      'createRepoOnCreate': createRepoOnCreate,
      'buildAutoDownload': buildAutoDownload,
      'buildServerRelay': buildServerRelay,
      'policyAcceptedVersion': policyAcceptedVersion,
      'policyAcceptedAt': policyAcceptedAt,
      // 旧字段继续输出，便于旧版本读取；Key 是否输出由 includeSecrets 决定
      'llmApiBase': llm?.apiBase ?? llmApiBase,
      'llmApiKey': includeSecrets ? (llm?.apiKey ?? llmApiKey) : '',
      'llmModel': llm?.model ?? llmModel,
      'llmProfiles': llmProfiles
          .map((profile) => profile.toJson(includeKey: includeSecrets))
          .toList(),
      'activeLlmId': activeLlmId,
      'llmUseBuiltin': llmUseBuiltin,
      'builtinLlmId': builtinLlmId,
      'llmCloudSync': llmCloudSync,
      'chatCloudSync': chatCloudSync,
      'syncNetwork': syncNetwork,
      'wallpaperCloudVersion': wallpaperCloudVersion,
      'backgroundImagePath': backgroundImagePath,
      'backgroundImageScope': backgroundImageScope,
      'backgroundImageOpacity': backgroundImageOpacity,
      'aiFloatingBallEnabled': aiFloatingBallEnabled,
      'systemOverlayEnabled': systemOverlayEnabled,
      'liveNotifications': liveNotifications,
      'githubHostsEnabled': githubHostsEnabled,
      'completionEnabled': completionEnabled,
      'volumeKeyCompletionEnabled': volumeKeyCompletionEnabled,
      'homeTitle': homeTitle,
      'avatarPath': avatarPath,
      'homeCustomTexts': homeCustomTexts,
      'homeSayingSourceEnabled': homeSayingSourceEnabled,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final mode = json['themeMode'] as String?;

    // 多模型配置；为空且旧字段有值时做一次性迁移
    final profiles = <LlmProfile>[];
    final rawProfiles = json['llmProfiles'];
    if (rawProfiles is List) {
      for (final item in rawProfiles) {
        if (item is Map) {
          profiles.add(LlmProfile.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    var activeLlmId = json['activeLlmId'] as String? ?? '';
    if (profiles.isEmpty) {
      final legacyBase = json['llmApiBase'] as String? ?? '';
      if (legacyBase.isNotEmpty) {
        final legacyModel = json['llmModel'] as String? ?? '';
        profiles.add(
          LlmProfile(
            id: 'legacy',
            name: '默认模型',
            apiBase: legacyBase,
            apiKey: json['llmApiKey'] as String? ?? '',
            model: legacyModel.isEmpty ? defaults.llmModel : legacyModel,
          ),
        );
        activeLlmId = 'legacy';
      }
    }

    return AppSettings(
      themeMode: switch (mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      editorFontSize:
          (json['editorFontSize'] as num?)?.toDouble() ??
          defaults.editorFontSize,
      language: switch (json['language'] as String?) {
        'zhHant' => 'zhHant',
        'en' => 'en',
        _ => 'zh',
      },
      fontFamily: json['fontFamily'] as String? ?? defaults.fontFamily,
      aiApprovalEnabled:
          json['aiApprovalEnabled'] as bool? ?? defaults.aiApprovalEnabled,
      agentApprovalMode: switch (json['agentApprovalMode'] as String?) {
        'manual' => 'manual',
        'auto' => 'auto',
        'full' => 'full',
        'custom' => 'custom',
        _ => defaults.agentApprovalMode,
      },
      agentApprovalRules:
          json['agentApprovalRules'] as String? ?? defaults.agentApprovalRules,
      appLockEnabled:
          json['appLockEnabled'] as bool? ?? defaults.appLockEnabled,
      showSaying: json['showSaying'] as bool? ?? defaults.showSaying,
      defaultGitHost: GitHost.fromId(
        json['defaultGitHost'] as String?,
        fallback: GitHost.github,
      ),
      createRepoOnCreate:
          json['createRepoOnCreate'] as bool? ?? defaults.createRepoOnCreate,
      buildAutoDownload:
          json['buildAutoDownload'] as bool? ?? defaults.buildAutoDownload,
      buildServerRelay:
          json['buildServerRelay'] as bool? ?? defaults.buildServerRelay,
      policyAcceptedVersion:
          json['policyAcceptedVersion'] as String? ??
          defaults.policyAcceptedVersion,
      policyAcceptedAt:
          json['policyAcceptedAt'] as String? ?? defaults.policyAcceptedAt,
      llmApiBase: json['llmApiBase'] as String? ?? defaults.llmApiBase,
      llmApiKey: json['llmApiKey'] as String? ?? defaults.llmApiKey,
      llmModel: json['llmModel'] as String? ?? defaults.llmModel,
      llmProfiles: profiles,
      activeLlmId: activeLlmId,
      llmUseBuiltin: json['llmUseBuiltin'] as bool? ?? defaults.llmUseBuiltin,
      builtinLlmId: json['builtinLlmId'] as String? ?? defaults.builtinLlmId,
      llmCloudSync: json['llmCloudSync'] as bool? ?? defaults.llmCloudSync,
      chatCloudSync: json['chatCloudSync'] as bool? ?? defaults.chatCloudSync,
      syncNetwork: json['syncNetwork'] as String? ?? defaults.syncNetwork,
      wallpaperCloudVersion:
          json['wallpaperCloudVersion'] as String? ??
          defaults.wallpaperCloudVersion,
      backgroundImagePath:
          json['backgroundImagePath'] as String? ??
          defaults.backgroundImagePath,
      backgroundImageScope: switch (json['backgroundImageScope'] as String?) {
        backgroundScopeIdeOnly => backgroundScopeIdeOnly,
        _ => defaults.backgroundImageScope,
      },
      backgroundImageOpacity:
          (json['backgroundImageOpacity'] as num?)?.toDouble() ??
          defaults.backgroundImageOpacity,
      aiFloatingBallEnabled:
          json['aiFloatingBallEnabled'] as bool? ??
          defaults.aiFloatingBallEnabled,
      systemOverlayEnabled:
          json['systemOverlayEnabled'] as bool? ??
          defaults.systemOverlayEnabled,
      liveNotifications:
          json['liveNotifications'] as bool? ?? defaults.liveNotifications,
      githubHostsEnabled:
          json['githubHostsEnabled'] as bool? ?? defaults.githubHostsEnabled,
      completionEnabled:
          json['completionEnabled'] as bool? ?? defaults.completionEnabled,
      volumeKeyCompletionEnabled:
          json['volumeKeyCompletionEnabled'] as bool? ??
          defaults.volumeKeyCompletionEnabled,
      homeTitle: json['homeTitle'] as String? ?? defaults.homeTitle,
      avatarPath: json['avatarPath'] as String? ?? defaults.avatarPath,
      homeCustomTexts: switch (json['homeCustomTexts']) {
        final List list => [
          for (final item in list)
            if (item is String && item.trim().isNotEmpty) item.trim(),
        ],
        _ => const [],
      },
      homeSayingSourceEnabled:
          json['homeSayingSourceEnabled'] as bool? ??
          defaults.homeSayingSourceEnabled,
    );
  }
}
