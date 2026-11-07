import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/github_provider.dart';
import '../services/github_api_service.dart';

/// GitHub 用户抽屉：首页点击 GitHub 头像时弹出。
///
/// 展示用户基本信息（头像、昵称、用户名、简介、仓库/粉丝数据）
/// 以及 GitHub Actions 的剩余用量。
class GitHubUserDrawer extends StatefulWidget {
  const GitHubUserDrawer({super.key});

  @override
  State<GitHubUserDrawer> createState() => _GitHubUserDrawerState();
}

class _GitHubUserDrawerState extends State<GitHubUserDrawer> {
  late Future<ActionsBilling?> _billingFuture;

  @override
  void initState() {
    super.initState();
    _billingFuture = _loadBilling();
  }

  Future<ActionsBilling?> _loadBilling() async {
    final token = context.read<GitHubProvider>().token;
    if (token == null || token.isEmpty) return null;
    try {
      return await GitHubApiService(token).getActionsBilling();
    } catch (_) {
      // 授权范围不足或网络失败 → 显示「无法获取」
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final github = context.watch<GitHubProvider>();
    final user = github.user;

    return Drawer(
      width: 320,
      child: SafeArea(
        child: user == null
            ? const Center(child: Text('未登录 GitHub'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(isDark, user),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildStatsRow(isDark, user),
                        const SizedBox(height: 20),
                        _buildBillingCard(isDark),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _buildFooter(isDark, github),
                ],
              ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 头部：头像 / 昵称 / 用户名 / 简介
  // ---------------------------------------------------------------------------

  Widget _buildHeader(bool isDark, GitHubUser user) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      color: isDark ? const Color(0xFF161B22) : const Color(0xFFF6F8FA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.grey[300],
            backgroundImage: user.avatarUrl != null
                ? NetworkImage(user.avatarUrl!)
                : null,
            child: user.avatarUrl == null ? const Icon(Icons.person) : null,
          ),
          const SizedBox(height: 12),
          Text(
            user.name ?? user.login,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '@${user.login}',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
          if (user.bio != null && user.bio!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              user.bio!,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 统计数据：公开仓库 / 粉丝 / 正在关注
  // ---------------------------------------------------------------------------

  Widget _buildStatsRow(bool isDark, GitHubUser user) {
    Widget stat(String label, int? value) {
      return Expanded(
        child: Column(
          children: [
            Text(
              value?.toString() ?? '-',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        stat('公开仓库', user.publicRepos),
        stat('粉丝', user.followers),
        stat('正在关注', user.following),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Actions 用量卡片
  // ---------------------------------------------------------------------------

  Widget _buildBillingCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161B22) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_outline, size: 18),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Actions 用量',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '刷新',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () =>
                    setState(() => _billingFuture = _loadBilling()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<ActionsBilling?>(
            future: _billingFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final billing = snapshot.data;
              if (billing == null) {
                return Text(
                  '当前授权无法读取用量信息',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                );
              }
              final used = billing.totalMinutesUsed;
              final included = billing.includedMinutes;
              final remaining = billing.remainingMinutes;
              final progress =
                  included > 0 ? (used / included).clamp(0.0, 1.0) : 0.0;
              final exhausted = remaining <= 0;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor:
                          isDark ? Colors.white12 : Colors.black12,
                      valueColor: AlwaysStoppedAnimation(
                        exhausted ? Colors.redAccent : const Color(0xFF1F6FEB),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '已用 ${_fmtMinutes(used)} / 包含 ${_fmtMinutes(included)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    exhausted
                        ? '免费额度已用尽'
                        : '剩余 ${_fmtMinutes(remaining)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: exhausted
                          ? Colors.redAccent
                          : const Color(0xFF1F6FEB),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _fmtMinutes(double minutes) {
    if (minutes >= 1000) {
      return '${(minutes / 1000).toStringAsFixed(1)}k 分钟';
    }
    return '${minutes.toStringAsFixed(0)} 分钟';
  }

  // ---------------------------------------------------------------------------
  // 底部：退出登录
  // ---------------------------------------------------------------------------

  Widget _buildFooter(bool isDark, GitHubProvider github) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: OutlinedButton.icon(
        onPressed: () async {
          Navigator.of(context).pop();
          await github.signOut();
        },
        icon: const Icon(Icons.logout, size: 18),
        label: const Text('退出 GitHub 登录'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.redAccent,
          side: const BorderSide(color: Colors.redAccent),
        ),
      ),
    );
  }
}
