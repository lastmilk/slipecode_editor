import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../providers/account_provider.dart';
import '../screens/custom_payload_manager_screen.dart';
import '../services/community_service.dart';
import 'community_theme.dart';
import 'covenant_screen.dart';
import 'post_detail_screen.dart';

/// 我的：资料 / 我的帖子 / 我的 Payload / 公约
class MyTab extends StatefulWidget {
  const MyTab({super.key});

  @override
  State<MyTab> createState() => _MyTabState();
}

class _MyTabState extends State<MyTab> with AutomaticKeepAliveClientMixin {
  List<CommunityPost> _posts = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await CommunityService.instance.myPosts();
      if (!mounted) return;
      setState(() {
        _posts = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _posts = [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final account = context.watch<AccountProvider>();
    final user = account.user;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CommunityTheme.border),
            ),
            child: Row(
              children: [
                TAvatar(
                  size: TAvatarSize.large,
                  child: Text(
                    (user?.displayName.isNotEmpty ?? false)
                        ? user!.displayName.characters.first
                        : '?',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.displayName.isNotEmpty == true ? user!.displayName : '未登录',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        user == null ? '登录后可发帖、评论与发布 Payload' : user.email,
                        style: const TextStyle(fontSize: 11, color: CommunityTheme.textSecondary),
                      ),
                      if (user != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${user.membership.planName} · ${user.credits} 积分',
                          style: const TextStyle(fontSize: 11, color: CommunityTheme.brand),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _actionCard(
                  icon: Icons.extension_outlined,
                  label: '我的 Payload',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CustomPayloadManagerScreen()),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _actionCard(
                  icon: Icons.menu_book_outlined,
                  label: '社区公约',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CovenantScreen()),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Text('我的帖子', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text('${_posts.length}', style: const TextStyle(fontSize: 12, color: CommunityTheme.textSecondary)),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_posts.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CommunityTheme.border),
              ),
              child: const TEmpty(emptyText: '还没有发过帖子'),
            )
          else
            for (final post in _posts) _postCard(post),
        ],
      ),
    );
  }

  Widget _actionCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CommunityTheme.border),
        ),
        child: Column(
          children: [
            Icon(icon, size: 22, color: CommunityTheme.brand),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _postCard(CommunityPost post) {
    final color = post.isPublished
        ? const Color(0xFF00A870)
        : (post.isRejected ? const Color(0xFFD54941) : const Color(0xFFED7B2F));
    final label = post.isPublished ? '已发布' : (post.isRejected ? '已驳回' : '待审核');
    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PostDetailScreen(postId: post.id)),
        );
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: CommunityTheme.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(post.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  if (post.reviewNote.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text('审核备注：${post.reviewNote}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Color(0xFFD54941))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label, style: TextStyle(fontSize: 10, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}
