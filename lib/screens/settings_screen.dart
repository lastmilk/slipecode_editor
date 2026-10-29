import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../providers/account_provider.dart';
import '../providers/settings_provider.dart';
import '../services/git_host.dart';
import '../widgets/ai_floating_ball.dart';
import 'account_screen.dart';

/// 偏好设置页面
///
/// 配置 IDE 行为（主题、编辑器字号、自动保存、首页语句、Git 默认平台），
/// 登录 SlipCode 账号后设置会自动同步到其他设备。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final account = context.watch<AccountProvider>();
    final settings = settingsProvider.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('偏好设置'),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SyncCard(account: account),
          const SizedBox(height: 16),

          _Section(
            title: '外观',
            isDark: isDark,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('主题模式')),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('跟随系统'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('浅色'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('深色'),
                        ),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (value) =>
                          settingsProvider.setThemeMode(value.first),
                    ),
                  ],
                ),
              ),
              const Divider(height: 16),

              // 背景图片：选择 / 预览缩略图 / 清除
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('背景图片')),
                    if (settings.backgroundImagePath.isNotEmpty &&
                        File(settings.backgroundImagePath).existsSync())
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(settings.backgroundImagePath),
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => _pickBackgroundImage(context),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(
                        settings.backgroundImagePath.isEmpty ? '选择图片' : '更换',
                      ),
                    ),
                    if (settings.backgroundImagePath.isNotEmpty)
                      TextButton(
                        onPressed: settingsProvider.clearBackgroundImage,
                        child: const Text('清除'),
                      ),
                  ],
                ),
              ),

              // 已设置背景图时才显示范围与不透明度选项
              if (settings.backgroundImagePath.isNotEmpty) ...[
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
                            settingsProvider.setBackgroundScope(value.first),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('不透明度')),
                      Text(
                        settings.backgroundImageOpacity.toStringAsFixed(2),
                        style: const TextStyle(fontFeatures: [
                          FontFeature.tabularFigures(),
                        ]),
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
                  onChanged: settingsProvider.setBackgroundOpacity,
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: '编辑器',
            isDark: isDark,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动保存'),
                subtitle: const Text('编辑文件后自动写入并同步到远程仓库'),
                value: settings.autoSave,
                onChanged: settingsProvider.setAutoSave,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Expanded(child: Text('代码字号')),
                    Text(
                      settings.editorFontSize.toStringAsFixed(0),
                      style: const TextStyle(fontFeatures: [
                        FontFeature.tabularFigures(),
                      ]),
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
                onChanged: settingsProvider.setEditorFontSize,
              ),
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: '首页',
            isDark: isDark,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示随机语句'),
                subtitle: const Text('每次打开首页用打字机效果显示一句随机语句'),
                value: settings.showSaying,
                onChanged: settingsProvider.setShowSaying,
              ),
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: 'Git 与项目',
            isDark: isDark,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认 Git 平台'),
                subtitle: const Text('创建项目时默认使用的托管平台'),
                trailing: DropdownButton<GitHost>(
                  value: settings.defaultGitHost,
                  underline: const SizedBox.shrink(),
                  items: GitHost.values
                      .map(
                        (host) => DropdownMenuItem(
                          value: host,
                          child: Text(host.label),
                        ),
                      )
                      .toList(),
                  onChanged: (host) {
                    if (host != null) {
                      settingsProvider.setDefaultGitHost(host);
                    }
                  },
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('创建项目时自动建仓并推送'),
                subtitle: const Text('默认勾选是否创建远程仓库并推送模板文件'),
                value: settings.createRepoOnCreate,
                onChanged: settingsProvider.setCreateRepoOnCreate,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('iOS 构建'),
                subtitle: const Text(
                  'iOS 只能在 GitHub Actions 的 macOS Runner 上构建；'
                  'Gitee Go 不支持 macOS，因此选择 Gitee 时 iOS 构建会被禁用',
                ),
                leading: const Icon(Icons.apple),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: 'AI 助手（LLM）',
            isDark: isDark,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.auto_awesome),
                title: const Text('API 地址'),
                subtitle: Text(
                  settings.isLlmConfigured ? '已配置' : '未配置',
                  style: TextStyle(
                    color: settings.isLlmConfigured
                        ? Colors.green
                        : Colors.orange,
                    fontSize: 11,
                  ),
                ),
                onTap: () => _editText(
                  context,
                  title: 'LLM API 地址',
                  hint: 'https://api.openai.com/v1',
                  value: settings.llmApiBase,
                  onSave: settingsProvider.setLlmApiBase,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key),
                title: const Text('API Key'),
                subtitle: Text(
                  settings.llmApiKey.isEmpty ? '未设置' : '已设置（仅存本地）',
                  style: TextStyle(
                    color: settings.llmApiKey.isEmpty
                        ? Colors.orange
                        : Colors.green,
                    fontSize: 11,
                  ),
                ),
                onTap: () => _editText(
                  context,
                  title: 'LLM API Key',
                  hint: 'sk-...',
                  value: settings.llmApiKey,
                  obscure: true,
                  onSave: settingsProvider.setLlmApiKey,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.psychology),
                title: const Text('模型名称'),
                subtitle: Text(settings.llmModel),
                onTap: () => _editText(
                  context,
                  title: '模型名称',
                  hint: 'gpt-4o-mini',
                  value: settings.llmModel,
                  onSave: settingsProvider.setLlmModel,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '对接任意 OpenAI 兼容接口（OpenAI / 通义千问 / DeepSeek / 本地模型等）。'
                  '凭据仅保存在本地，不会上传。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: 'AI 悬浮球',
            isDark: isDark,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('应用内悬浮球'),
                subtitle: const Text('在 IDE 右下角显示 AI 悬浮球，点击呼出 Agent 面板'),
                value: settings.aiFloatingBallEnabled,
                onChanged: settingsProvider.setAiFloatingBallEnabled,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('系统悬浮球'),
                subtitle: Text(
                  Platform.isAndroid
                      ? 'App 退到后台后仍显示悬浮球（需授予悬浮窗权限）'
                      : 'iOS 不支持系统悬浮窗，仅可使用应用内悬浮球',
                ),
                value: settings.systemOverlayEnabled,
                onChanged: Platform.isAndroid
                    ? (value) async {
                        final ok = await toggleSystemOverlay(value);
                        if (!context.mounted) return;
                        if (value && !ok) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('未授予悬浮窗权限，无法开启系统悬浮球'),
                            ),
                          );
                          return;
                        }
                        settingsProvider.setSystemOverlayEnabled(ok);
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 16),

          _Section(
            title: '代码补全',
            isDark: isDark,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('语法补全建议'),
                subtitle: const Text('输入时在编辑器顶部显示关键字 / 组件 / 代码片段建议'),
                value: settings.completionEnabled,
                onChanged: settingsProvider.setCompletionEnabled,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('音量上键 = Tab / 接受补全'),
                subtitle: Text(
                  Platform.isAndroid
                      ? '显示建议时接受补全；无建议时插入缩进。'
                          '关闭后音量上键仅在有建议时生效，其余时候恢复正常音量调节。'
                      : 'iOS 不支持音量键映射，请使用建议条右侧的「补全」按钮。',
                ),
                value: settings.volumeKeyCompletionEnabled,
                onChanged: Platform.isAndroid
                    ? settingsProvider.setVolumeKeyCompletionEnabled
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'SlipCode · 偏好设置保存在本地，登录账号后同步到云端',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    required this.isDark,
  });

  final String title;
  final List<Widget> children;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D30) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
            ),
          ),
          child: Column(children: children),
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
                      : '登录 SlipCode 账号以同步设置',
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

/// 选择本地图片并复制到应用文档目录，再保存持久化路径到偏好设置
Future<void> _pickBackgroundImage(BuildContext context) async {
  final settingsProvider = context.read<SettingsProvider>();
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: '选择背景图片',
    );
    final srcPath = result?.files.single.path;
    if (srcPath == null || srcPath.isEmpty) return; // 用户取消

    // 复制到应用文档目录持久化，避免源图片被移动/删除后背景丢失
    final docsDir = await getApplicationDocumentsDirectory();
    final bgDir = Directory('${docsDir.path}/backgrounds');
    if (!bgDir.existsSync()) {
      bgDir.createSync(recursive: true);
    }
    final ext = srcPath.contains('.') ? srcPath.split('.').last : 'png';
    final destPath =
        '${bgDir.path}/background_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File(srcPath).copy(destPath);

    await settingsProvider.setBackgroundImage(destPath);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择背景图片失败: $e')),
      );
    }
  }
}

/// 弹出文本编辑对话框，用于编辑 LLM 配置项
Future<void> _editText(
  BuildContext context, {
  required String title,
  required String hint,
  required String value,
  required Future<void> Function(String) onSave,
  bool obscure = false,
}) async {
  final controller = TextEditingController(text: value);
  var obscureText = obscure;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscureText,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: obscure
                ? IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () =>
                        setDialogState(() => obscureText = !obscureText),
                  )
                : null,
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
    ),
  );
  if (confirmed == true) {
    await onSave(controller.text);
  }
}
