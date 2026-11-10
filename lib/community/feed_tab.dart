import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../services/community_service.dart';
import 'community_theme.dart';
import 'post_detail_screen.dart';

/// 推荐流：帖子列表
class FeedTab extends StatefulWidget {
  const FeedTab({super.key, this.onCompose});

  final VoidCallback? onCompose;

  @override
  State<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<FeedTab>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final _service = CommunityService.instance;

  List<CommunityPost> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String _error = '';
  String _tab = 'latest';
  int _page = 1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      if (_hasMore && !_loadingMore) _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = '';
        _page = 1;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final result = await _service.fetchFeed(
        tab: _tab,
        page: _page,
        pageSize: 10,
      );
      if (!mounted) return;
      setState(() {
        _posts = reset ? result.posts : [..._posts, ...result.posts];
        _hasMore = result.hasMore;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$e';
      });
    }
  }

  void _switchTab(String tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              _tabPill('最新', 'latest'),
              const SizedBox(width: 8),
              _tabPill('热门', 'hot'),
              const Spacer(),
              if (widget.onCompose != null)
                TextButton.icon(
                  onPressed: widget.onCompose,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('发帖'),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: _buildBody(),
          ),
        ),
      ],
    );
  }

  Widget _tabPill(String label, String value) {
    final selected = _tab == value;
    return GestureDetector(
      onTap: () => _switchTab(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? CommunityTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? CommunityTheme.brand : CommunityTheme.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : CommunityTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _posts.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          TEmpty(emptyText: _error),
          Center(
            child: TButton(
              child: const Text('重试'),
              variant: TButtonVariant.outline,
              size: TButtonSize.small,
              onPressed: () => _load(reset: true),
            ),
          ),
        ],
      );
    }
    if (_posts.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          TEmpty(emptyText: '还没有帖子，来发布第一篇吧'),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _posts.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _posts.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _PostCard(
          post: _posts[index],
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PostDetailScreen(postId: _posts[index].id),
              ),
            );
            _load(reset: true);
          },
        );
      },
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.onTap});

  final CommunityPost post;
  final VoidCallback onTap;

  String? get _timeText {
    final t = post.createdAt;
    if (t == null) return null;
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: CommunityTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CommunityTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TAvatar(
                  size: TAvatarSize.medium,
                  child: Text(
                    post.authorName.isEmpty ? '?' : post.authorName.characters.first,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    post.authorName.isEmpty ? '匿名' : post.authorName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: CommunityTheme.textPrimary,
                    ),
                  ),
                ),
                if (_timeText != null)
                  Text(
                    _timeText!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: CommunityTheme.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              post.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.35,
                color: CommunityTheme.textPrimary,
              ),
            ),
            if (post.excerpt.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                post.excerpt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: CommunityTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                for (final tag in post.tags.take(3))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TTag(
                      tag,
                      size: TTagSize.small,
                      variant: TTagVariant.light,
                    ),
                  ),
                const Spacer(),
                Icon(Icons.favorite_border, size: 14, color: CommunityTheme.textSecondary),
                const SizedBox(width: 3),
                Text('${post.likes}', style: const TextStyle(fontSize: 11, color: CommunityTheme.textSecondary)),
                const SizedBox(width: 12),
                Icon(Icons.chat_bubble_outline, size: 13, color: CommunityTheme.textSecondary),
                const SizedBox(width: 3),
                Text('${post.commentCount}', style: const TextStyle(fontSize: 11, color: CommunityTheme.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
