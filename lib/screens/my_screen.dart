import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/account_provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/image_crop_dialog.dart';
import '../widgets/main_bottom_nav.dart';
import '../widgets/project_creation_flow.dart';
import 'account_screen.dart';
import 'authorization_screen.dart';
import 'credit_logs_screen.dart';
import 'login_devices_screen.dart';
import 'recharge_screen.dart';
import 'settings_screen.dart';

/// 「我的」：SLIPE 账号中心
///
/// 布局参考豆包账号页：头像 / 昵称 / SLIPE 号 + 积分与套餐 +
/// 升级套餐、手机号、邮箱、登录设备、授权管理、积分流水、云同步、注销 / 退出。
class MyScreen extends StatefulWidget {
  const MyScreen({super.key});

  @override
  State<MyScreen> createState() => _MyScreenState();
}

class _MyScreenState extends State<MyScreen> {
  bool _uploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = context.read<AccountProvider>();
      if (!account.isSignedIn) return;
      account.refreshCredits();
      account.refreshCreditLogs();
      account.refreshDevices();
      if (account.billing.plans.isEmpty) account.loadBillingPlans();
    });
  }

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
      if (!mounted) return;
      if (account.isSignedIn) {
        setState(() => _uploadingAvatar = true);
        final ok = await account.uploadAvatar(cropped);
        if (!mounted) return;
        setState(() => _uploadingAvatar = false);
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

  Future<void> _syncNow() async {
    final account = context.read<AccountProvider>();
    final ok = await account.syncNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已从云端同步设置' : (account.error ?? '同步失败')),
        backgroundColor: ok ? Colors.green : Colors.orange,
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    final account = context.read<AccountProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将不再同步偏好设置、头像与积分信息，确定退出？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await account.signOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录')),
    );
  }

  Future<void> _confirmDeleteAccount() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('注销账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '注销后将删除账号、积分、社区帖子与评论，且无法恢复。\n请输入密码确认。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '账号密码',
                prefixIcon: Icon(Icons.lock_outline, size: 18),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null) return;
    if (!mounted) return;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入密码')),
      );
      return;
    }
    final account = context.read<AccountProvider>();
    final (ok, message) = await account.deleteAccount(password);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ok ? Colors.green : Colors.orange,
      ),
    );
  }

  Future<void> _showInfo(String title, String value) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(value),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          '我的',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '偏好设置',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: account.isSignedIn ? _buildProfile(account, isDark) : _buildSignedOut(isDark),
      bottomNavigationBar: MainBottomNav(
        current: MainTab.my,
        onCenterTap: () => showCreateProjectFlow(context),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 已登录
  // ---------------------------------------------------------------------------

  Widget _buildProfile(AccountProvider account, bool isDark) {
    final user = account.user;
    final membership = user?.membership;
    final planName = (membership?.active ?? false)
        ? membership!.planName
        : '免费版';
    final lastSync = account.lastSyncAt;

    return RefreshIndicator(
      onRefresh: () async {
        await account.refreshUserInfo();
        await account.refreshCredits();
        await account.refreshDevices();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _buildHeader(account, isDark),
          const SizedBox(height: 18),
          _buildSummary(account, isDark, planName),
          const SizedBox(height: 14),
          _card(isDark, [
            _tile(
              icon: Icons.auto_awesome,
              iconColor: const Color(0xFF7C4DFF),
              title: '升级套餐',
              trailing: planName,
              isDark: isDark,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RechargeScreen()),
                );
                if (mounted) account.refreshUserInfo();
              },
            ),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.phone_iphone_rounded,
              iconColor: const Color(0xFF4CAF50),
              title: '手机号',
              trailing: _maskPhone(user?.phone ?? ''),
              isDark: isDark,
              onTap: () => _showInfo('手机号', user?.phone ?? '未绑定'),
            ),
            _divider(isDark),
            _tile(
              icon: Icons.alternate_email_rounded,
              iconColor: const Color(0xFF1E88E5),
              title: '邮箱',
              trailing: user?.email ?? '',
              isDark: isDark,
              onTap: () => _showInfo('邮箱', user?.email ?? '未绑定'),
            ),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.devices_rounded,
              iconColor: const Color(0xFF1E88E5),
              title: '登录设备管理',
              trailing: '${account.devices.length}',
              isDark: isDark,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginDevicesScreen()),
                );
                if (mounted) account.refreshDevices();
              },
            ),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.apps_rounded,
              iconColor: const Color(0xFF1E88E5),
              title: '授权管理',
              trailing: _authorizationSummary(context),
              isDark: isDark,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuthorizationScreen()),
              ),
            ),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.receipt_long_rounded,
              iconColor: const Color(0xFF00897B),
              title: '积分流水',
              trailing: '${account.credits} 积分',
              isDark: isDark,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreditLogsScreen()),
              ),
            ),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.sync_rounded,
              iconColor: const Color(0xFF5E6AD2),
              title: '立即同步',
              trailing: lastSync == null
                  ? '未同步'
                  : '${lastSync.month.toString().padLeft(2, '0')}-'
                      '${lastSync.day.toString().padLeft(2, '0')} '
                      '${lastSync.hour.toString().padLeft(2, '0')}:'
                      '${lastSync.minute.toString().padLeft(2, '0')}',
              isDark: isDark,
              onTap: _syncNow,
            ),
            _divider(isDark),
            _buildSyncNetworkTile(isDark),
          ]),
          _card(isDark, [
            _tile(
              icon: Icons.delete_outline_rounded,
              iconColor: const Color(0xFFE53935),
              title: '注销账号',
              isDark: isDark,
              onTap: _confirmDeleteAccount,
            ),
            _divider(isDark),
            _tile(
              icon: Icons.logout_rounded,
              iconColor: const Color(0xFFE53935),
              title: '退出登录',
              isDark: isDark,
              onTap: _confirmSignOut,
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildHeader(AccountProvider account, bool isDark) {
    final user = account.user;
    final avatarPath = context.watch<SettingsProvider>().settings.avatarPath;
    final hasAvatar = avatarPath.isNotEmpty && File(avatarPath).existsSync();
    final name = (user?.displayName.isNotEmpty ?? false)
        ? user!.displayName
        : (user?.email ?? 'SLIPE 用户');
    final initial = name.trim().isEmpty ? 'S' : name.trim().substring(0, 1);

    return Column(
      children: [
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _uploadingAvatar ? null : _pickAvatar,
          child: Stack(
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: hasAvatar
                      ? null
                      : const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF5B8DEF), Color(0xFF2F6BE4)],
                        ),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.white,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: hasAvatar
                    ? Image.file(File(avatarPath), fit: BoxFit.cover)
                    : Center(
                        child: Text(
                          initial.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? Colors.white12 : const Color(0xFFE3E5E8),
                    ),
                  ),
                  child: _uploadingAvatar
                      ? const Padding(
                          padding: EdgeInsets.all(7),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.photo_camera_outlined,
                          size: 15,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          name,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : const Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'SLIPE号：${(user?.id ?? '').replaceFirst('u_', '').toUpperCase()}',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
          ),
        ),
      ],
    );
  }

  /// 头像下方：积分余额 + 当前套餐（替代参考图中的「账号管理」按钮）
  Widget _buildSummary(AccountProvider account, bool isDark, String planName) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreditLogsScreen()),
              ),
              child: Column(
                children: [
                  Text(
                    '${account.credits}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '可用积分',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 34,
            color: isDark ? Colors.white12 : const Color(0xFFEFF1F3),
          ),
          Expanded(
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RechargeScreen()),
              ),
              child: Column(
                children: [
                  Text(
                    planName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前套餐',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncNetworkTile(bool isDark) {
    final sp = context.watch<SettingsProvider>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          _iconBox(Icons.wifi_rounded, const Color(0xFF5E6AD2)),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('同步网络策略', style: TextStyle(fontSize: 14)),
          ),
          DropdownButton<String>(
            value: sp.settings.syncNetwork,
            underline: const SizedBox.shrink(),
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
            items: const [
              DropdownMenuItem(value: 'wifi', child: Text('仅 Wi-Fi')),
              DropdownMenuItem(value: 'any', child: Text('任意网络')),
              DropdownMenuItem(value: 'never', child: Text('关闭自动同步')),
            ],
            onChanged: (value) {
              if (value != null) sp.setSyncNetwork(value);
            },
          ),
        ],
      ),
    );
  }

  String _authorizationSummary(BuildContext context) {
    final github = context.watch<GitHubProvider>().isSignedIn;
    final gitee = context.watch<GiteeProvider>().isSignedIn;
    if (github && gitee) return 'GitHub · Gitee';
    if (github) return 'GitHub';
    if (gitee) return 'Gitee';
    return '未授权';
  }

  // ---------------------------------------------------------------------------
  // 未登录
  // ---------------------------------------------------------------------------

  Widget _buildSignedOut(bool isDark) {
    final configured = context.read<AccountProvider>().isConfigured;
    final github = context.watch<GitHubProvider>();
    final gitee = context.watch<GiteeProvider>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
      children: [
        Center(
          child: Container(
            width: 92,
            height: 92,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF5B8DEF), Color(0xFF2F6BE4)],
              ),
            ),
            child: const Icon(
              Icons.person_rounded,
              size: 46,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            '登录 SLIPE 账号',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF1A1A1A),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '同步偏好设置、头像、积分与会员权益',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
            ),
          ),
        ),
        const SizedBox(height: 26),
        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: configured
                ? () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AccountScreen()),
                    )
                : null,
            child: Text(configured ? '登录 / 注册' : '账号后端未配置'),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '或使用代码托管账号授权',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                ),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: github.status == GitHubAuthStatus.signingIn
                    ? github.cancelSignIn
                    : () => github.signIn(),
                icon: const Icon(Icons.code, size: 18),
                label: Text(github.isSignedIn
                    ? (github.user?.login ?? 'GitHub')
                    : 'GitHub 登录'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: gitee.status == GiteeAuthStatus.signingIn
                    ? gitee.cancelSignIn
                    : () => gitee.signIn(),
                icon: const Icon(Icons.cloud, size: 18),
                label: Text(gitee.isSignedIn
                    ? (gitee.user?.login ?? 'Gitee')
                    : 'Gitee 登录'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFC71D23),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'GitHub / Gitee 授权仅用于代码托管，与 SLIPE 账号相互独立。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white30 : const Color(0xFFB0B5BC),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 通用组件
  // ---------------------------------------------------------------------------

  Widget _card(bool isDark, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(children: children),
    );
  }

  Widget _divider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 60,
      color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
    );
  }

  Widget _iconBox(IconData icon, Color color) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }

  Widget _tile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool isDark,
    String? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        child: Row(
          children: [
            _iconBox(icon, iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (trailing != null && trailing.isNotEmpty)
              Flexible(
                child: Text(
                  trailing,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? Colors.white24 : const Color(0xFFC6CBD1),
            ),
          ],
        ),
      ),
    );
  }

  String _maskPhone(String phone) {
    final value = phone.trim();
    if (value.length < 7) return value.isEmpty ? '未绑定' : value;
    return '+86 ${value.substring(0, 3)}****${value.substring(value.length - 4)}';
  }
}
