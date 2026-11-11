import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';

/// 授权管理：GitHub / Gitee 代码托管账号的授权与解除
///
/// 与 SLIPE 账号相互独立，仅用于仓库拉取与 Actions 构建。
class AuthorizationScreen extends StatelessWidget {
  const AuthorizationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final github = context.watch<GitHubProvider>();
    final gitee = context.watch<GiteeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '授权管理',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _AuthCard(
            isDark: isDark,
            icon: Icons.code_rounded,
            color: isDark ? Colors.white : const Color(0xFF24292F),
            title: 'GitHub',
            subtitle: github.isSignedIn
                ? (github.user?.login ?? '已授权')
                : '未授权',
            avatarUrl: github.user?.avatarUrl,
            signingIn: github.status == GitHubAuthStatus.signingIn,
            signedIn: github.isSignedIn,
            onSignIn: () async {
              final ok = await github.signIn();
              if (!ok && github.error != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(github.error!)),
                );
              }
            },
            onSignOut: github.signOut,
            onCancel: github.cancelSignIn,
          ),
          const SizedBox(height: 12),
          _AuthCard(
            isDark: isDark,
            icon: Icons.cloud_rounded,
            color: const Color(0xFFC71D23),
            title: 'Gitee',
            subtitle: gitee.isSignedIn
                ? (gitee.user?.login ?? '已授权')
                : '未授权',
            avatarUrl: gitee.user?.avatarUrl,
            signingIn: gitee.status == GiteeAuthStatus.signingIn,
            signedIn: gitee.isSignedIn,
            onSignIn: () async {
              final ok = await gitee.signIn();
              if (!ok && gitee.error != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(gitee.error!)),
                );
              }
            },
            onSignOut: gitee.signOut,
            onCancel: gitee.cancelSignIn,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '授权后，SLIPE 可以读取你的仓库列表、拉取代码并触发 GitHub Actions 构建。'
              '解除授权不会删除任何仓库内容。',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: isDark ? Colors.white54 : const Color(0xFF8A8F99),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.isDark,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.signingIn,
    required this.signedIn,
    required this.onSignIn,
    required this.onSignOut,
    required this.onCancel,
    this.avatarUrl,
  });

  final bool isDark;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? avatarUrl;
  final bool signingIn;
  final bool signedIn;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final hasAvatar = (avatarUrl ?? '').isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: hasAvatar
                  ? null
                  : color.withValues(alpha: isDark ? 0.22 : 0.10),
              borderRadius: BorderRadius.circular(12),
              image: hasAvatar
                  ? DecorationImage(
                      image: NetworkImage(avatarUrl!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: hasAvatar
                ? null
                : Icon(icon, size: 22, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: signedIn ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (signingIn)
            TextButton(
              onPressed: onCancel,
              child: const Text('取消', style: TextStyle(fontSize: 12)),
            )
          else if (signedIn)
            OutlinedButton(
              onPressed: onSignOut,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('解除授权', style: TextStyle(fontSize: 12)),
            )
          else
            FilledButton(
              onPressed: onSignIn,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('去授权', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
