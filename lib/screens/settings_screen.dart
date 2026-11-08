import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/llm_profile.dart';
import '../models/mcp_config.dart';
import '../providers/account_provider.dart';
import '../providers/settings_provider.dart';
import '../services/ai_extensions_service.dart';
import '../services/docs_service.dart';
import '../services/external_mcp_manager.dart';
import '../services/git_host.dart';
import '../services/llm_presets.dart';
import '../services/security_service.dart';
import '../widgets/ai_floating_ball.dart';
import '../widgets/credits_sheet.dart';
import '../widgets/image_crop_dialog.dart';
import 'account_screen.dart';

/// 偏好设置页面
///
/// 按「外观 / 编辑器 / 项目与Git / AI模型 / AI助手 / 账号与同步」分 Tab，
/// 顶部搜索框可跨 Tab 过滤设置项；登录 SLIPE 账号后设置可同步到其他设备。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  List<String> get _tabNames => [
    t('settings.tab.appearance'),
    t('settings.tab.editor'),
    t('settings.tab.git'),
    t('settings.tab.llm'),
    t('settings.tab.ai'),
    t('settings.tab.security'),
    t('settings.tab.account'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabNames.length, vsync: this);
    // 加载用户配置的第三方 MCP 与外源 Skill
    AiExtensionsService.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final account = context.watch<AccountProvider>();
    final settings = settingsProvider.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final searching = _query.trim().isNotEmpty;

    // 各 Tab 的分区数据（搜索时跨 Tab 统一过滤）
    final tabSections = <List<_SectionData>>[
      _appearanceSections(settingsProvider, settings, isDark),
      _editorSections(settingsProvider, settings),
      _gitSections(settingsProvider, settings),
      _llmSections(settingsProvider, account, settings),
      _aiSections(settingsProvider, settings),
      _securitySections(settingsProvider, settings),
      _accountSections(account, settingsProvider, settings, isDark),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(t('settings.title')),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: t('settings.search'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: searching
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              if (!searching)
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [for (final name in _tabNames) Tab(text: name)],
                ),
            ],
          ),
        ),
      ),
      body: searching
          ? _buildSearchResults(tabSections, isDark)
          : TabBarView(
              controller: _tabController,
              children: [
                for (final sections in tabSections)
                  _SettingsTab(sections: sections, isDark: isDark),
              ],
            ),
    );
  }

  /// 搜索结果：跨 Tab 扁平展示匹配项，并标注所属位置
  Widget _buildSearchResults(
    List<List<_SectionData>> tabSections,
    bool isDark,
  ) {
    final query = _query.trim().toLowerCase();
    final results = <Widget>[];
    for (var tabIndex = 0; tabIndex < tabSections.length; tabIndex++) {
      for (final section in tabSections[tabIndex]) {
        final matched = section.entries
            .where((e) => e.keywords.toLowerCase().contains(query))
            .toList();
        if (matched.isEmpty) continue;
        results.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8, top: 16),
            child: Text(
              '${_tabNames[tabIndex]} · ${section.title}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
        );
        results.add(
          _SectionCard(
            isDark: isDark,
            children: [for (final e in matched) e.child],
          ),
        );
      }
    }
    if (results.isEmpty) {
      return Center(
        child: Text(
          '没有找到与「$_query」相关的设置',
          style: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: results,
    );
  }

  // ---------------------------------------------------------------------------
  // 各 Tab 内容
  // ---------------------------------------------------------------------------

  List<_SectionData> _appearanceSections(
    SettingsProvider sp,
    AppSettings settings,
    bool isDark,
  ) {
    final hasWallpaper = settings.backgroundImagePath.isNotEmpty;
    final isVideo =
        hasWallpaper &&
        settings.backgroundImagePath.toLowerCase().endsWith('.mp4');
    return [
      _SectionData('语言与字体', [
        _Entry(
          '界面语言 简体 繁体 英文 language locale english',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('settings.language')),
            subtitle: Text(t('settings.languageSub')),
            // DropdownButton 的宽度取「最宽菜单项」，不约束会把标题挤成竖排
            trailing: SizedBox(
              width: 132,
              child: DropdownButton<String>(
                value: settings.language,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final option in appLanguageOptions)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(
                        option.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) sp.setLanguage(value);
                },
              ),
            ),
          ),
        ),
        _Entry(
          '字体 font family typeface',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('settings.font')),
            subtitle: Text(t('settings.fontSub')),
            trailing: SizedBox(
              width: 132,
              child: DropdownButton<String>(
                value: settings.fontFamily,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final option in appFontOptions)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(
                        option.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) sp.setFontFamily(value);
                },
              ),
            ),
          ),
        ),
      ]),
      _SectionData('主题', [
        _Entry(
          '主题模式 深色 浅色 跟随系统 appearance theme',
          // SegmentedButton 过宽，标题与控件上下排列，避免标题被挤成竖排
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('主题模式'),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                      ),
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (value) => sp.setThemeMode(value.first),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
      _SectionData('壁纸', [
        _Entry(
          '壁纸 背景图片 动态壁纸 gif mp4 wallpaper background',
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Expanded(child: Text('壁纸（支持 GIF / MP4）')),
                if (hasWallpaper &&
                    File(settings.backgroundImagePath).existsSync())
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: isVideo
                          ? const SizedBox(
                              width: 40,
                              height: 40,
                              child: ColoredBox(
                                color: Colors.black26,
                                child: Icon(Icons.play_circle_outline),
                              ),
                            )
                          : Image.file(
                              File(settings.backgroundImagePath),
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _pickWallpaper,
                  icon: const Icon(Icons.image_outlined, size: 16),
                  label: Text(hasWallpaper ? '更换' : '选择壁纸'),
                ),
                if (hasWallpaper)
                  TextButton(
                    onPressed: sp.clearBackgroundImage,
                    child: const Text('清除'),
                  ),
              ],
            ),
          ),
        ),
        _Entry(
          '壁纸云端同步 wallpaper cloud sync 大小限制',
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '静态壁纸（≤5MB）登录后自动上传云端并在 Wi-Fi 下同步到其他设备；'
              'GIF / MP4 动态壁纸仅保存在本机，不参与云同步。',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ),
        ),
        if (hasWallpaper) ...[
          _Entry(
            '壁纸显示范围 全局 仅编辑器 scope',
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Expanded(child: Text('显示范围')),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: AppSettings.backgroundScopeGlobal,
                        label: Text('全局'),
                      ),
                      ButtonSegment(
                        value: AppSettings.backgroundScopeIdeOnly,
                        label: Text('仅编辑器'),
                      ),
                    ],
                    selected: {settings.backgroundImageScope},
                    onSelectionChanged: (value) =>
                        sp.setBackgroundScope(value.first),
                  ),
                ],
              ),
            ),
          ),
          _Entry(
            '壁纸不透明度 opacity',
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('不透明度')),
                      Text(
                        settings.backgroundImageOpacity.toStringAsFixed(2),
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Slider(
                  min: 0,
                  max: 1,
                  divisions: 20,
                  value: settings.backgroundImageOpacity,
                  label: settings.backgroundImageOpacity.toStringAsFixed(2),
                  onChanged: sp.setBackgroundOpacity,
                ),
              ],
            ),
          ),
        ],
      ]),
      _SectionData('首页', [
        _Entry(
          '首页标题 home title',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('首页标题'),
            subtitle: Text(settings.homeTitle),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => _editText(
              context,
              title: '首页标题',
              hint: '留空则使用默认 SLIPE',
              value: settings.homeTitle,
              onSave: sp.setHomeTitle,
            ),
          ),
        ),
        _Entry(
          '显示随机语句 打字机 saying typewriter',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示随机语句'),
            subtitle: const Text('每次打开首页用打字机效果显示一句随机语句'),
            value: settings.showSaying,
            onChanged: sp.setShowSaying,
          ),
        ),
        _Entry(
          '首页文案库 自定义文案 custom texts',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('首页文案库'),
            subtitle: Text(
              settings.homeCustomTexts.isEmpty
                  ? '未设置（使用一言源）'
                  : '已设置 ${settings.homeCustomTexts.length} 条',
            ),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => _editHomeTexts(context, sp, settings),
          ),
        ),
        if (settings.homeCustomTexts.isNotEmpty)
          _Entry(
            '混入一言源 saying source mix',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('混入一言源'),
              subtitle: const Text('开启后每次启动各有 50% 概率显示一言或自定义文案'),
              value: settings.homeSayingSourceEnabled,
              onChanged: sp.setHomeSayingSourceEnabled,
            ),
          ),
      ]),
    ];
  }

  List<_SectionData> _editorSections(
    SettingsProvider sp,
    AppSettings settings,
  ) {
    return [
      _SectionData('编辑行为', [
        _Entry(
          '代码字号 font size',
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Expanded(child: Text('代码字号')),
                    Text(
                      settings.editorFontSize.toStringAsFixed(0),
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Slider(
                min: 11,
                max: 22,
                divisions: 11,
                value: settings.editorFontSize,
                label: settings.editorFontSize.toStringAsFixed(0),
                onChanged: sp.setEditorFontSize,
              ),
            ],
          ),
        ),
      ]),
      _SectionData('代码补全', [
        _Entry(
          '语法补全建议 completion suggestion',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('语法补全建议'),
            subtitle: const Text('输入时在编辑器顶部显示关键字 / 组件 / 代码片段建议'),
            value: settings.completionEnabled,
            onChanged: sp.setCompletionEnabled,
          ),
        ),
        _Entry(
          '音量键控制 补全 volume key',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('音量键控制（下键切换 / 上键确认）'),
            subtitle: Text(
              Platform.isAndroid
                  ? '编辑器内音量键不再调节音量。有补全候选时，音量下键切换候选、音量上键确认；'
                        '无候选时音量下键唤出文件栏。关闭后恢复系统音量调节。'
                  : 'iOS 不支持音量键映射，请使用建议条上的上一条 / 下一条 / 补全按钮。',
            ),
            value: settings.volumeKeyCompletionEnabled,
            onChanged: Platform.isAndroid
                ? sp.setVolumeKeyCompletionEnabled
                : null,
          ),
        ),
      ]),
    ];
  }

  List<_SectionData> _gitSections(SettingsProvider sp, AppSettings settings) {
    return [
      _SectionData('Git 平台', [
        _Entry(
          '默认 Git 平台 github gitee',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('默认 Git 平台'),
            subtitle: const Text('创建项目时默认使用的托管平台'),
            trailing: DropdownButton<GitHost>(
              value: settings.defaultGitHost,
              underline: const SizedBox.shrink(),
              items: GitHost.values
                  .map(
                    (host) =>
                        DropdownMenuItem(value: host, child: Text(host.label)),
                  )
                  .toList(),
              onChanged: (host) {
                if (host != null) sp.setDefaultGitHost(host);
              },
            ),
          ),
        ),
        _Entry(
          '创建项目时自动建仓并推送 auto repo push',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('创建项目时自动建仓并推送'),
            subtitle: const Text('默认勾选是否创建远程仓库并推送模板文件'),
            value: settings.createRepoOnCreate,
            onChanged: sp.setCreateRepoOnCreate,
          ),
        ),
        _Entry(
          '构建产物自动下载 auto download artifact',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('完成后自动下载构建产物'),
            subtitle: const Text(
              '云端构建成功后自动把 APK / AAB / zip 下载到项目 build/github 目录',
            ),
            value: settings.buildAutoDownload,
            onChanged: sp.setBuildAutoDownload,
          ),
        ),
        _Entry(
          '构建产物服务端中转 server relay',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('优先通过服务端中转产物'),
            subtitle: const Text(
              '登录用户默认由服务端先下载产物再下发到本地，缓解国内访问 GitHub 慢的问题；关闭后直接访问 GitHub 下载',
            ),
            value: settings.buildServerRelay,
            onChanged: sp.setBuildServerRelay,
          ),
        ),
        _Entry(
          'iOS 构建 macos runner',
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('iOS 构建'),
            subtitle: Text(
              'iOS 只能在 GitHub Actions 的 macOS Runner 上构建；'
              'Gitee Go 不支持 macOS，因此选择 Gitee 时 iOS 构建会被禁用',
            ),
            leading: Icon(Icons.apple),
          ),
        ),
      ]),
    ];
  }

  List<_SectionData> _llmSections(
    SettingsProvider sp,
    AccountProvider account,
    AppSettings settings,
  ) {
    final profiles = settings.llmProfiles;
    return [
      _SectionData('SLIPE 内置模型', [
        _Entry(
          'SLIPE 内置模型 deepseek stepfun 积分 大模型 免费额度',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用 SLIPE 内置大模型'),
            subtitle: const Text(
              '登录后直接在对话框底部使用，按积分计费，无需自备 API Key。'
              '注册赠送 500 积分，默认使用 DeepSeek Flash。',
            ),
            value: settings.llmUseBuiltin,
            onChanged: (value) async {
              await sp.setUseBuiltinLlm(value);
              if (value) await account.refreshBuiltinModels();
            },
          ),
        ),
        if (account.builtinModels.isNotEmpty)
          for (final model in account.builtinModels)
            _Entry(
              '内置模型 ${model.name} ${model.id} 倍率 ${model.multiplier}',
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  settings.llmUseBuiltin &&
                          model.id == (settings.builtinLlmId.isEmpty
                              ? account.defaultBuiltinModelId
                              : settings.builtinLlmId)
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: settings.llmUseBuiltin &&
                          model.id == (settings.builtinLlmId.isEmpty
                              ? account.defaultBuiltinModelId
                              : settings.builtinLlmId)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                title: Row(
                  children: [
                    Text(model.name),
                    if (model.isDefault) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '默认',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${model.description.isEmpty ? '由 SLIPE 提供' : model.description}'
                  ' · 倍率 ${model.multiplier} · 约 '
                  '${model.tokensPerCredit} Tokens/积分',
                  style: const TextStyle(fontSize: 11, height: 1.3),
                ),
                onTap: () => sp.setBuiltinLlm(model.id),
              ),
            )
        else
          _Entry(
            '内置模型 登录 注册赠送 500 积分',
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                account.isSignedIn
                    ? '内置模型列表加载中，请检查网络后重试…'
                    : '登录 SLIPE 账号后即可使用内置模型，注册即赠送 500 积分。',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ),
      ]),
      _SectionData('模型列表', [
        for (final profile in profiles)
          _Entry(
            '模型 ${profile.name} ${profile.model} ${profile.apiBase} llm provider',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                !settings.llmUseBuiltin && profile.id == settings.activeLlmId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: !settings.llmUseBuiltin &&
                        profile.id == settings.activeLlmId
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
              title: Text(profile.name),
              subtitle: Text(
                '${profile.model}\n${profile.apiBase}',
                style: const TextStyle(fontSize: 11, height: 1.3),
              ),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    tooltip: '编辑',
                    onPressed: () =>
                        _editProfile(context, sp, account, profile),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除',
                    onPressed: () => _removeProfile(context, sp, profile),
                  ),
                ],
              ),
              onTap: () => sp.setActiveLlm(profile.id),
            ),
          ),
        _Entry(
          '添加模型配置 add llm provider preset',
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: OutlinedButton.icon(
              onPressed: () => _editProfile(context, sp, account, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加模型配置'),
            ),
          ),
        ),
        _Entry(
          '模型配置说明 openai 兼容 api key',
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '支持任意 OpenAI 兼容接口（OpenAI / DeepSeek / 通义 / 本地 Ollama 等）。'
              'API Key 默认仅保存在本机。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ),
      ]),
      _SectionData('同步', [
        _Entry(
          '模型配置云同步 llm cloud sync api key 上传',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('模型配置云同步'),
            subtitle: const Text(
              '开启后模型列表（含 API Key）会随账号上传到云端，'
              '请仅在信任自建后端时开启',
            ),
            value: settings.llmCloudSync,
            onChanged: sp.setLlmCloudSync,
          ),
        ),
      ]),
    ];
  }

  List<_SectionData> _aiSections(SettingsProvider sp, AppSettings settings) {
    return [
      _SectionData('AI 改动', [
        _Entry(
          'AI 改动 自动保存 撤回 未批准 推送 git push',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('AI 改动默认保存，可随时撤回'),
            subtitle: const Text(
              'AI 修改文件后直接落盘，不再弹窗审批；'
              '在对话流或退出时可逐条撤回。未确认的改动不会被推送到 GitHub / Gitee。',
            ),
          ),
        ),
      ]),
      _SectionData('AI 助手', [
        _Entry(
          '对话记录云同步 chat history cloud',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('对话记录云同步'),
            subtitle: const Text('开启后 AI 助手对话记录上传到云端，可在多设备间查看'),
            value: settings.chatCloudSync,
            onChanged: sp.setChatCloudSync,
          ),
        ),
        _Entry(
          '应用内悬浮球 floating ball agent',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('应用内悬浮球'),
            subtitle: const Text('在 IDE 右下角显示 AI 悬浮球，点击弹出轻量 AI 对话窗'),
            value: settings.aiFloatingBallEnabled,
            onChanged: sp.setAiFloatingBallEnabled,
          ),
        ),
        _Entry(
          '系统悬浮球 overlay 悬浮窗权限',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('系统悬浮球'),
            subtitle: Text(
              Platform.isAndroid
                  ? 'App 退到后台后仍显示悬浮球（需授予悬浮窗权限）；'
                      '点击后可直接选择项目并输入需求，AI 自动执行'
                  : 'iOS 不支持系统悬浮窗，仅可使用应用内悬浮球',
            ),
            value: settings.systemOverlayEnabled,
            onChanged: Platform.isAndroid
                ? (value) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final ok = await toggleSystemOverlay(value);
                    if (value && !ok) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('未授予悬浮窗权限，无法开启系统悬浮球')),
                      );
                      return;
                    }
                    sp.setSystemOverlayEnabled(ok);
                  }
                : null,
          ),
        ),
        _Entry(
          'vibecoding 说明 回车触发',
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'VibeCoding：在编辑器行首输入「..需求」或「。。需求」后回车，'
              'AI 会在该位置自动生成代码；生成期间可在文件管理器的 Agent 页查看思考过程。',
              style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
            ),
          ),
        ),
      ]),
      _SectionData('第三方 MCP', [
        _Entry(
          '第三方 MCP 服务器 配置 导入 mcpServers SSE stdio',
          const _McpServersCard(),
        ),
      ]),
      _SectionData('外源 Skill', [
        _Entry(
          '外源 Skill 导入 markdown 提示词 skill',
          const _ImportedSkillsCard(),
        ),
      ]),
    ];
  }

  List<_SectionData> _securitySections(
    SettingsProvider sp,
    AppSettings settings,
  ) {
    return [
      _SectionData('应用锁', [
        _Entry(
          '应用锁 生物认证 指纹 面容 解锁密码 biometric app lock',
          _SecurityCard(settingsProvider: sp, settings: settings),
        ),
      ]),
    ];
  }

  List<_SectionData> _accountSections(
    AccountProvider account,
    SettingsProvider sp,
    AppSettings settings,
    bool isDark,
  ) {
    return [
      _SectionData('积分与充值', [
        _Entry(
          '积分 充值 余额 签到 激活码 套餐 流水 credits billing',
          const CreditsPanel(),
        ),
      ]),
      _SectionData('账号', [
        _Entry('账号同步状态 sync account login', _SyncCard(account: account)),
        _Entry(
          '头像 账号头像 avatar 上传 裁剪',
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Expanded(child: Text('头像（与账号绑定）')),
                if (settings.avatarPath.isNotEmpty &&
                    File(settings.avatarPath).existsSync())
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipOval(
                      child: Image.file(
                        File(settings.avatarPath),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _pickAvatar,
                  icon: const Icon(Icons.image_outlined, size: 16),
                  label: Text(settings.avatarPath.isEmpty ? '选择头像' : '更换'),
                ),
                if (settings.avatarPath.isNotEmpty)
                  TextButton(
                    onPressed: sp.clearAvatar,
                    child: const Text('恢复默认'),
                  ),
              ],
            ),
          ),
        ),
        _Entry(
          '头像说明 云端 avatar cloud',
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              '登录后头像自动上传到云端（≤2MB），并同步到所有设备。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ),
      ]),
      _SectionData('云同步', [
        _Entry(
          '同步网络策略 wifi 流量 network policy',
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同步网络策略'),
            subtitle: const Text('控制壁纸 / 对话记录等自动同步使用的网络'),
            trailing: DropdownButton<String>(
              value: settings.syncNetwork,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'wifi', child: Text('仅 Wi-Fi')),
                DropdownMenuItem(value: 'any', child: Text('任意网络')),
                DropdownMenuItem(value: 'never', child: Text('关闭自动同步')),
              ],
              onChanged: (value) {
                if (value != null) sp.setSyncNetwork(value);
              },
            ),
          ),
        ),
      ]),
      _SectionData('官方社群', [
        _Entry('官方 QQ 群 qq group community', const _QqGroupTile()),
      ]),
    ];
  }

  // ---------------------------------------------------------------------------
  // LLM 配置编辑
  // ---------------------------------------------------------------------------

  /// 新增 / 编辑模型配置
  Future<void> _editProfile(
    BuildContext context,
    SettingsProvider sp,
    AccountProvider account,
    LlmProfile? existing,
  ) async {
    final result = await showDialog<LlmProfile>(
      context: context,
      builder: (_) => _ProfileEditDialog(existing: existing),
    );
    if (result == null) return;
    await sp.upsertLlmProfile(result);
    if (existing == null) {
      await sp.setActiveLlm(result.id);
    }
  }

  Future<void> _removeProfile(
    BuildContext context,
    SettingsProvider sp,
    LlmProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${profile.name}」？'),
        content: const Text('删除后无法恢复，该配置仅移除本机与云端的这一条记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sp.removeLlmProfile(profile.id);
    }
  }

  // ---------------------------------------------------------------------------
  // 头像 / 壁纸选择（含自由剪裁与云端上传）
  // ---------------------------------------------------------------------------

  /// 选择头像 → 1:1 裁剪为 512×512 → 本地保存 → 登录时上传云端
  Future<void> _pickAvatar() async {
    final settingsProvider = context.read<SettingsProvider>();
    final account = context.read<AccountProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: '选择头像',
      );
      final srcPath = result?.files.single.path;
      if (srcPath == null || srcPath.isEmpty) return;

      final docsDir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final destPath =
          '${docsDir.path}/avatars/avatar_${DateTime.now().millisecondsSinceEpoch}.png';
      final cropped = await showImageCropDialog(
        context,
        sourcePath: srcPath,
        aspectRatio: 1.0,
        outputPath: destPath,
      );
      if (cropped == null) return;

      await settingsProvider.setAvatarPath(cropped);
      if (account.isSignedIn) {
        final ok = await account.uploadAvatar(cropped);
        messenger.showSnackBar(
          SnackBar(
            content: Text(ok ? '头像已同步到云端' : '头像已保存本机，云端上传失败'),
            backgroundColor: ok ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('选择头像失败: $e')));
    }
  }

  /// 选择壁纸 → 静态图按屏幕比例裁剪，GIF/MP4 直接保存 → 符合条件时上传云端
  Future<void> _pickWallpaper() async {
    final settingsProvider = context.read<SettingsProvider>();
    final account = context.read<AccountProvider>();
    final messenger = ScaffoldMessenger.of(context);
    // 屏幕比例在异步间隙前取好，避免跨 await 使用 context
    final screenSize = MediaQuery.of(context).size;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4'],
        dialogTitle: '选择壁纸（图片 / GIF / MP4）',
      );
      final srcPath = result?.files.single.path;
      if (srcPath == null || srcPath.isEmpty) return;

      final ext = srcPath.contains('.')
          ? srcPath.split('.').last.toLowerCase()
          : 'png';
      final docsDir = await getApplicationDocumentsDirectory();
      final bgDir = Directory('${docsDir.path}/backgrounds');
      if (!bgDir.existsSync()) bgDir.createSync(recursive: true);
      final destPath =
          '${bgDir.path}/background_${DateTime.now().millisecondsSinceEpoch}.$ext';

      String savedPath;
      if (ext == 'gif' || ext == 'mp4') {
        // 动图 / 视频无法逐帧裁剪，直接复制
        await File(srcPath).copy(destPath);
        savedPath = destPath;
      } else {
        // 静态图：按屏幕比例自由裁剪，铺满效果更好
        if (!mounted) return;
        final cropped = await showImageCropDialog(
          context,
          sourcePath: srcPath,
          aspectRatio: screenSize.width / screenSize.height,
          outputPath: destPath,
        );
        if (cropped == null) return;
        savedPath = cropped;
      }

      await settingsProvider.setBackgroundImage(savedPath);
      if (account.isSignedIn && ext != 'gif' && ext != 'mp4') {
        final ok = await account.uploadWallpaper(savedPath);
        if (!ok) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('壁纸已保存本机（超过 5MB 或网络受限，未上传云端）'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('选择壁纸失败: $e')));
    }
  }
}

// =============================================================================
// 数据模型与复用组件
// =============================================================================

/// 一个可搜索的设置项：child 为展示组件，keywords 用于搜索匹配
class _Entry {
  const _Entry(this.keywords, this.child);
  final String keywords;
  final Widget child;
}

/// 一个分区（标题 + 若干设置项）
class _SectionData {
  const _SectionData(this.title, this.entries);
  final String title;
  final List<_Entry> entries;
}

/// Tab 页：纵向列出所有分区
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.sections, required this.isDark});

  final List<_SectionData> sections;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (final section in sections) ...[
          _SectionHeader(title: section.title, isDark: isDark),
          _SectionCard(
            isDark: isDark,
            children: [for (final e in section.entries) e.child],
          ),
          const SizedBox(height: 16),
        ],
        Center(
          child: Text(
            'SLIPE · 偏好设置保存在本地，登录账号后同步到云端',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.isDark});

  final String title;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white60 : Colors.black54,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children, required this.isDark});

  final List<Widget> children;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(children: children),
    );
  }
}

/// 应用锁设置卡片（生物认证 + 密码兜底）
class _SecurityCard extends StatefulWidget {
  const _SecurityCard({required this.settingsProvider, required this.settings});

  final SettingsProvider settingsProvider;
  final AppSettings settings;

  @override
  State<_SecurityCard> createState() => _SecurityCardState();
}

class _SecurityCardState extends State<_SecurityCard> {
  bool _hasPassword = false;
  bool _biometricAvailable = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hasPassword = await SecurityService.instance.hasPassword();
    final available = await SecurityService.instance.biometricAvailable();
    if (!mounted) return;
    setState(() {
      _hasPassword = hasPassword;
      _biometricAvailable = available;
    });
  }

  Future<void> _toggleLock(bool enable) async {
    final messenger = ScaffoldMessenger.of(context);
    if (enable) {
      if (!_hasPassword) {
        final ok = await _promptPassword();
        if (!ok) return;
      }
      if (!_biometricAvailable) {
        messenger.showSnackBar(
          SnackBar(content: Text(t('settings.biometricUnavailable'))),
        );
      }
      await SecurityService.instance.setBiometricEnabled(true);
      await widget.settingsProvider.setAppLockEnabled(true);
    } else {
      await SecurityService.instance.setBiometricEnabled(false);
      await widget.settingsProvider.setAppLockEnabled(false);
    }
    if (mounted) await _load();
  }

  /// 设置 / 修改解锁密码；返回是否设置成功
  Future<bool> _promptPassword({bool requireOld = false}) async {
    final oldController = TextEditingController();
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    String? error;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            requireOld
                ? t('settings.changePassword')
                : t('settings.setPassword'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (requireOld)
                TextField(
                  controller: oldController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
              TextField(
                controller: controller,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: t('settings.setPassword'),
                ),
              ),
              TextField(
                controller: confirmController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认密码'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: () async {
                if (controller.text.length < 4) {
                  setDialogState(() => error = '密码至少需要 4 位');
                  return;
                }
                if (controller.text != confirmController.text) {
                  setDialogState(() => error = '两次输入的密码不一致');
                  return;
                }
                if (requireOld &&
                    !await SecurityService.instance.verifyPassword(
                      oldController.text,
                    )) {
                  setDialogState(() => error = '当前密码错误');
                  return;
                }
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop(true);
              },
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      await SecurityService.instance.setPassword(controller.text);
    }
    oldController.dispose();
    controller.dispose();
    confirmController.dispose();
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.settings.appLockEnabled;
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.lock_outline),
          title: Text(t('settings.security')),
          subtitle: Text(t('settings.securitySub')),
          value: enabled,
          onChanged: _busy
              ? null
              : (value) async {
                  setState(() => _busy = true);
                  await _toggleLock(value);
                  if (mounted) setState(() => _busy = false);
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('settings.setPassword')),
          subtitle: Text(
            _hasPassword
                ? t('settings.passwordSet')
                : t('settings.passwordNotSet'),
          ),
          trailing: TextButton(
            onPressed: () async {
              final ok = await _promptPassword(requireOld: _hasPassword);
              if (ok) await _load();
            },
            child: Text(
              _hasPassword
                  ? t('settings.changePassword')
                  : t('settings.setPassword'),
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('settings.biometric')),
          subtitle: Text(
            _biometricAvailable
                ? '指纹 / 面容 / 虹膜'
                : t('settings.biometricUnavailable'),
          ),
          trailing: Icon(
            _biometricAvailable ? Icons.fingerprint : Icons.no_accounts,
            color: _biometricAvailable ? Colors.green : Colors.grey,
          ),
        ),
      ],
    );
  }
}

/// 账号同步状态卡片
class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.account});

  final AccountProvider account;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final signedIn = account.isSignedIn;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF1F3A4D), Color(0xFF1B2B36)]
              : const [Color(0xFFE3F2FD), Color(0xFFF1F8FE)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF2E5A75) : const Color(0xFFBBDEFB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                signedIn ? Icons.cloud_done : Icons.cloud_off,
                size: 20,
                color: Colors.blueAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  signedIn
                      ? '设置同步已开启（${account.user?.displayName ?? account.user?.email ?? ''}）'
                      : '登录 SLIPE 账号以同步设置',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            signedIn
                ? (account.lastSyncAt == null
                      ? '尚未同步，点右侧按钮立即同步'
                      : '上次同步：${_format(account.lastSyncAt!)}')
                : '账号与设置独立于 GitHub / Gitee，登录后可在多台设备间同步偏好设置。',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          if (account.error != null && signedIn) ...[
            const SizedBox(height: 4),
            Text(
              account.error!,
              style: const TextStyle(fontSize: 11, color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                ),
                child: Text(signedIn ? '管理账号' : '登录 / 注册'),
              ),
              if (signedIn) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    final ok = await context.read<AccountProvider>().syncNow();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok ? '设置已从云端同步' : '同步失败'),
                        backgroundColor: ok ? Colors.green : Colors.redAccent,
                      ),
                    );
                  },
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('立即同步'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _format(DateTime time) {
    return '${time.month}月${time.day}日 ${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
}

// =============================================================================
// LLM 配置编辑对话框
// =============================================================================

class _ProfileEditDialog extends StatefulWidget {
  const _ProfileEditDialog({this.existing});

  final LlmProfile? existing;

  @override
  State<_ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<_ProfileEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _apiBase;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late String _presetId;
  bool _obscure = true;

  LlmPreset? get _preset => LlmPresets.byId(_presetId);

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _apiBase = TextEditingController(text: existing?.apiBase ?? '');
    _apiKey = TextEditingController(text: existing?.apiKey ?? '');
    _model = TextEditingController(text: existing?.model ?? '');
    _presetId = existing?.presetId ?? 'deepseek';
    if (existing == null) _applyPreset(_presetId);
  }

  @override
  void dispose() {
    _name.dispose();
    _apiBase.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  /// 选择预置后自动填充名称 / 地址 / 默认模型
  void _applyPreset(String presetId) {
    final preset = LlmPresets.byId(presetId);
    if (preset == null) return;
    _presetId = presetId;
    _name.text = preset.name;
    _apiBase.text = LlmPresets.apiBaseFor(preset);
    if (preset.defaultModel.isNotEmpty) {
      _model.text = preset.defaultModel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    final isCloud = preset?.requiresLogin ?? false;
    final modelOptions = preset?.models ?? const <String>[];

    return AlertDialog(
      title: Text(widget.existing == null ? '添加模型配置' : '编辑模型配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _presetId,
              decoration: const InputDecoration(
                labelText: '服务商',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in LlmPresets.list)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _applyPreset(value));
              },
            ),
            if (preset?.note != null && preset!.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    preset.note,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiBase,
              enabled: !isCloud,
              decoration: InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.openai.com/v1',
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: isCloud ? '云端模型地址由账号后端自动决定' : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: isCloud ? 'API Key（云端无需填写）' : 'API Key',
                hintText: 'sk-...',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (modelOptions.isNotEmpty)
              DropdownButtonFormField<String>(
                // 切换服务商时重建，让默认模型随预置刷新
                key: ValueKey('model_$_presetId'),
                initialValue: modelOptions.contains(_model.text)
                    ? _model.text
                    : null,
                decoration: const InputDecoration(
                  labelText: '模型',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in modelOptions)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (value) {
                  if (value != null) _model.text = value;
                },
              )
            else
              TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  hintText: 'gpt-4o-mini',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final model = _model.text.trim();
            if (name.isEmpty || model.isEmpty) return;
            Navigator.of(context).pop(
              LlmProfile(
                id: widget.existing?.id ?? LlmProfile.newId(),
                name: name,
                apiBase: isCloud
                    ? LlmPresets.apiBaseFor(preset!)
                    : _apiBase.text.trim(),
                apiKey: _apiKey.text.trim(),
                model: model,
                presetId: _presetId == 'custom' ? null : _presetId,
                requiresLogin: isCloud,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 弹出文本编辑对话框
Future<void> _editText(
  BuildContext context, {
  required String title,
  required String hint,
  required String value,
  required Future<void> Function(String) onSave,
}) async {
  final controller = TextEditingController(text: value);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await onSave(controller.text);
  }
}

/// 弹出首页文案库编辑对话框（一行一条，空行自动过滤）
Future<void> _editHomeTexts(
  BuildContext context,
  SettingsProvider sp,
  AppSettings settings,
) async {
  final controller = TextEditingController(
    text: settings.homeCustomTexts.join('\n'),
  );
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('首页文案库'),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 6,
          maxLines: 12,
          decoration: const InputDecoration(
            hintText: '一行一条文案，例如：\n今天也要加油写代码\n保持热爱，奔赴山海',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await sp.setHomeCustomTexts(controller.text.split('\n'));
  }
}

/// 官方 QQ 群磁贴：从后端拉取最新群号，支持一键复制；未配置时不显示
class _QqGroupTile extends StatefulWidget {
  const _QqGroupTile();

  @override
  State<_QqGroupTile> createState() => _QqGroupTileState();
}

class _QqGroupTileState extends State<_QqGroupTile> {
  String? _qqGroup;

  @override
  void initState() {
    super.initState();
    DocsService.instance.fetchQqGroup().then((value) {
      if (mounted) setState(() => _qqGroup = value);
    });
  }

  Future<void> _copy() async {
    final group = _qqGroup;
    if (group == null || group.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: group));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('QQ 群号 $group 已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _qqGroup;
    if (group == null || group.isEmpty) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.groups_outlined),
      title: const Text('官方 QQ 群'),
      subtitle: Text(group),
      trailing: IconButton(
        tooltip: '复制群号',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: _copy,
      ),
      onTap: _copy,
    );
  }
}

// =============================================================================
// 第三方 MCP 服务器
// =============================================================================

/// MCP 配置编辑对话框返回的草稿数据
typedef _McpDraft = ({
  String name,
  String transport,
  String url,
  Map<String, String> headers,
  String command,
  List<String> args,
  Map<String, String> env,
});

class _McpServersCard extends StatelessWidget {
  const _McpServersCard();

  @override
  Widget build(BuildContext context) {
    final service = AiExtensionsService.instance;
    final manager = ExternalMcpManager.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: Listenable.merge([service, manager]),
      builder: (context, _) {
        final servers = service.servers;
        final errors = manager.errors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '连接第三方 MCP 服务器后，AI 可直接调用其提供的工具。'
              '支持 Streamable HTTP / SSE / stdio（仅桌面端），'
              '配置仅保存在本机，不会上传云端。',
              style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
            ),
            const SizedBox(height: 8),
            if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '尚未配置 MCP 服务器',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
              ),
            for (final server in servers)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? Colors.white12 : const Color(0xFFE4E7EB),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      server.isStdio ? Icons.terminal : Icons.cloud_outlined,
                      size: 18,
                      color: server.enabled ? Colors.blueAccent : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            '${server.transport.toUpperCase()} · ${server.endpointLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color:
                                  isDark ? Colors.white38 : Colors.black45,
                            ),
                          ),
                          if (server.enabled && errors[server.id] != null)
                            Text(
                              '连接失败：${errors[server.id]}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.redAccent,
                              ),
                            )
                          else if (server.enabled &&
                              manager.hasServers &&
                              !errors.containsKey(server.id))
                            const Text(
                              '已连接',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.green,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Switch(
                      value: server.enabled,
                      onChanged: (value) =>
                          service.toggleServer(server.id, value),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: '编辑',
                      onPressed: () => _editServer(context, server),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '删除',
                      onPressed: () => service.removeServer(server.id),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _editServer(context, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加 MCP 服务器'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _importConfig(context),
                  icon: const Icon(Icons.data_object, size: 16),
                  label: const Text('粘贴配置'),
                ),
                if (servers.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => manager.refresh(service.enabledServers),
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: const Text('测试连接'),
                  ),
                TextButton.icon(
                  onPressed: () => _importConfigFile(context),
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('导入配置文件'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _editServer(
    BuildContext context,
    McpServerConfig? existing,
  ) async {
    final draft = await showDialog<_McpDraft>(
      context: context,
      builder: (_) => _McpServerEditDialog(existing: existing),
    );
    if (draft == null) return;
    final service = AiExtensionsService.instance;
    if (existing == null) {
      await service.addServer(
        name: draft.name,
        transport: draft.transport,
        url: draft.url,
        headers: draft.headers,
        command: draft.command,
        args: draft.args,
        env: draft.env,
      );
    } else {
      await service.updateServer(
        existing.copyWith(
          name: draft.name,
          transport: draft.transport,
          url: draft.url,
          headers: draft.headers,
          command: draft.command,
          args: draft.args,
          env: draft.env,
        ),
      );
    }
    // 保存后立即尝试连接，让用户在设置页就能看到连接结果
    await ExternalMcpManager.instance.refresh(service.enabledServers);
  }

  Future<void> _importConfig(BuildContext context) async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴 MCP 配置'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 16,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: '支持 Claude Desktop / Cursor 格式：\n'
                  '{\n'
                  '  "mcpServers": {\n'
                  '    "filesystem": {\n'
                  '      "command": "npx",\n'
                  '      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]\n'
                  '    },\n'
                  '    "remote": {"url": "https://example.com/mcp"}\n'
                  '  }\n'
                  '}',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    final result = await AiExtensionsService.instance.importConfig(raw);
    if (result.imported > 0) {
      await ExternalMcpManager.instance.refresh(
        AiExtensionsService.instance.enabledServers,
      );
    }
    if (!context.mounted) return;
    final message = result.error != null
        ? result.error!
        : '已导入 ${result.imported} 个配置'
            '${result.skipped > 0 ? '，跳过 ${result.skipped} 个' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: result.imported > 0 ? Colors.green : Colors.orange,
      ),
    );
  }

  Future<void> _importConfigFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
        dialogTitle: '选择 MCP 配置文件',
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      final raw = await File(path).readAsString();
      final imported = await AiExtensionsService.instance.importConfig(raw);
      if (imported.imported > 0) {
        await ExternalMcpManager.instance.refresh(
          AiExtensionsService.instance.enabledServers,
        );
      }
      if (!context.mounted) return;
      final message = imported.error != null
          ? imported.error!
          : '已导入 ${imported.imported} 个配置'
              '${imported.skipped > 0 ? '，跳过 ${imported.skipped} 个' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: imported.imported > 0 ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }
}

class _McpServerEditDialog extends StatefulWidget {
  const _McpServerEditDialog({this.existing});

  final McpServerConfig? existing;

  @override
  State<_McpServerEditDialog> createState() => _McpServerEditDialogState();
}

class _McpServerEditDialogState extends State<_McpServerEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.existing?.url ?? '',
  );
  late final TextEditingController _command = TextEditingController(
    text: widget.existing?.command ?? '',
  );
  late final TextEditingController _args = TextEditingController(
    text: (widget.existing?.args ?? const []).join('\n'),
  );
  late final TextEditingController _headers = TextEditingController(
    text: _formatPairs(widget.existing?.headers ?? const {}, ': '),
  );
  late final TextEditingController _env = TextEditingController(
    text: _formatPairs(widget.existing?.env ?? const {}, '='),
  );
  late String _transport = widget.existing?.transport ?? 'http';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _command.dispose();
    _args.dispose();
    _headers.dispose();
    _env.dispose();
    super.dispose();
  }

  static String _formatPairs(Map<String, String> map, String sep) =>
      map.entries.map((e) => '${e.key}$sep${e.value}').join('\n');

  static Map<String, String> _parsePairs(String raw, String sep) {
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final index = trimmed.indexOf(sep);
      if (index <= 0) continue;
      map[trimmed.substring(0, index).trim()] =
          trimmed.substring(index + sep.length).trim();
    }
    return map;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    final url = _url.text.trim();
    final command = _command.text.trim();
    if (_transport == 'stdio') {
      if (command.isEmpty) {
        setState(() => _error = 'stdio 方式需要填写启动命令');
        return;
      }
    } else if (url.isEmpty) {
      setState(() => _error = '请填写 MCP 服务器地址');
      return;
    }
    Navigator.of(context).pop<_McpDraft>((
      name: name,
      transport: _transport,
      url: url,
      headers: _parsePairs(_headers.text, ':'),
      command: command,
      args: _args.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      env: _parsePairs(_env.text, '='),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isStdio = _transport == 'stdio';
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _transport,
                decoration: const InputDecoration(
                  labelText: '传输方式',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'http', child: Text('Streamable HTTP')),
                  DropdownMenuItem(value: 'sse', child: Text('HTTP + SSE（旧版）')),
                  DropdownMenuItem(value: 'stdio', child: Text('stdio（桌面端）')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _transport = value);
                },
              ),
              const SizedBox(height: 12),
              if (isStdio) ...[
                TextField(
                  controller: _command,
                  decoration: const InputDecoration(
                    labelText: '启动命令',
                    hintText: '例如 npx',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _args,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '参数（一行一个）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _env,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '环境变量（每行 KEY=VALUE）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://example.com/mcp',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headers,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '请求头（每行 Key: Value）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

// =============================================================================
// 外源 Skill
// =============================================================================

class _ImportedSkillsCard extends StatelessWidget {
  const _ImportedSkillsCard();

  @override
  Widget build(BuildContext context) {
    final service = AiExtensionsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final skills = service.skills;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '导入 Markdown / 文本格式的 Skill，启用后会追加到 AI 的系统提示词中，'
              '让 AI 按你定义的规则工作。',
              style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
            ),
            const SizedBox(height: 8),
            if (skills.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '尚未导入 Skill',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
              ),
            for (final skill in skills)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? Colors.white12 : const Color(0xFFE4E7EB),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.menu_book_outlined,
                      size: 18,
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () => _showSkill(context, skill),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              skill.name,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              '${skill.content.length} 字符',
                              style: TextStyle(
                                fontSize: 10,
                                color:
                                    isDark ? Colors.white38 : Colors.black45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Switch(
                      value: skill.enabled,
                      onChanged: (value) =>
                          service.toggleSkill(skill.id, value),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '删除',
                      onPressed: () => service.removeSkill(skill.id),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _importSkillFile(context),
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('导入 Skill 文件'),
                ),
                TextButton.icon(
                  onPressed: () => _pasteSkill(context),
                  icon: const Icon(Icons.edit_note, size: 16),
                  label: const Text('粘贴内容'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _importSkillFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'markdown', 'txt'],
        dialogTitle: '选择 Skill 文件',
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      final content = await File(path).readAsString();
      if (content.trim().isEmpty) return;
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final name = fileName.replaceAll(RegExp(r'\.(md|markdown|txt)$'), '');
      await AiExtensionsService.instance.addSkill(name: name, content: content);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 Skill「$name」')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _pasteSkill(BuildContext context) async {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴 Skill 内容'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                minLines: 8,
                maxLines: 16,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Skill 内容（Markdown）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final name = nameController.text;
    final content = contentController.text;
    nameController.dispose();
    contentController.dispose();
    if (confirmed != true || content.trim().isEmpty) return;
    await AiExtensionsService.instance.addSkill(name: name, content: content);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Skill 已导入')),
    );
  }

  Future<void> _showSkill(BuildContext context, ImportedSkill skill) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(skill.name),
        content: SizedBox(
          width: 560,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: SelectableText(
                skill.content,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
