import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../providers/account_provider.dart';
import '../services/community_service.dart';
import 'community_theme.dart';

/// 帖子详情 + 评论
class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final _service = CommunityService.instance;
  final _commentController = TextEditingController();

  CommunityPost? _post;
  List<CommunityComment> _comments = [];
  bool _loading = true;
  bool _liked = false;
  bool _submitting = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final postResult = await _service.fetchPost(widget.postId);
      final comments = await _service.fetchComments(widget.postId);
      if (!mounted) return;
      setState(() {
        _post = postResult.post;
        _liked = postResult.liked;
        _comments = comments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleLike() async {
    final post = _post;
    if (post == null) return;
    try {
      final result = await _service.toggleLike(post.id);
      if (!mounted) return;
      setState(() {
        _liked = result.liked;
        _post = CommunityPost(
          id: post.id,
          authorId: post.authorId,
          authorName: post.authorName,
          title: post.title,
          content: post.content,
          excerpt: post.excerpt,
          tags: post.tags,
          status: post.status,
          likes: result.likes,
          commentCount: post.commentCount,
          createdAt: post.createdAt,
          updatedAt: post.updatedAt,
          reviewNote: post.reviewNote,
        );
      });
    } catch (e) {
      if (!mounted) return;
      TToast.showFail('$e', context: context);
    }
  }

  Future<void> _submitComment() async {
    final content = _commentController.text.trim();
    if (content.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final comment = await _service.createComment(widget.postId, content);
      if (!mounted) return;
      _commentController.clear();
      setState(() {
        _comments = [..._comments, comment];
        _submitting = false;
      });
      FocusScope.of(context).unfocus();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      TToast.showFail('$e', context: context);
    }
  }

  Future<void> _report() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('举报帖子'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '请说明违规原因，例如广告、辱骂、侵权',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _service.reportPost(widget.postId, reason.trim());
      if (!mounted) return;
      TToast.showSuccess('举报已提交，管理员会尽快处理', context: context);
    } catch (e) {
      if (!mounted) return;
      TToast.showFail('$e', context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CommunityTheme.wrap(
      context,
      Scaffold(
        backgroundColor: CommunityTheme.bg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: const Text('帖子详情', style: TextStyle(fontSize: 16, color: CommunityTheme.textPrimary)),
          iconTheme: const IconThemeData(color: CommunityTheme.textPrimary),
          actions: [
            IconButton(
              tooltip: '举报',
              onPressed: _report,
              icon: const Icon(Icons.flag_outlined, size: 20),
            ),
          ],
        ),
        body: _buildBody(isDark),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TEmpty(emptyText: _error),
            const SizedBox(height: 8),
            TButton(
              child: const Text('重试'),
              variant: TButtonVariant.outline,
              size: TButtonSize.small,
              onPressed: _load,
            ),
          ],
        ),
      );
    }
    final post = _post;
    if (post == null) return const Center(child: Text('帖子不存在'));
    final account = context.watch<AccountProvider>();
    final isAuthor = account.user?.id == post.authorId;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!post.isPublished)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: post.isRejected
                        ? const Color(0xFFFFF1F0)
                        : const Color(0xFFFFF7E6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    post.isRejected
                        ? '该帖子未通过审核：${post.reviewNote.isEmpty ? '请修改后重新发布' : post.reviewNote}'
                        : '该帖子正在审核中，仅你自己可见',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
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
                  Text(
                    post.authorName.isEmpty ? '匿名' : post.authorName,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (isAuthor)
                    TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除帖子'),
                            content: const Text('删除后评论也会一并删除，确定继续？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          try {
                            await _service.deletePost(post.id);
                            if (mounted) Navigator.of(context).pop();
                          } catch (e) {
                            if (mounted) TToast.showFail('$e', context: context);
                          }
                        }
                      },
                      child: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.red)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                post.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              MarkdownBody(
                data: post.content,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 14, height: 1.7),
                  code: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    backgroundColor: isDark ? Colors.black26 : const Color(0xFFF2F3F5),
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: isDark ? Colors.black26 : const Color(0xFFF2F3F5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  GestureDetector(
                    onTap: _toggleLike,
                    child: Row(
                      children: [
                        Icon(
                          _liked ? Icons.favorite : Icons.favorite_border,
                          size: 18,
                          color: _liked ? Colors.redAccent : CommunityTheme.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text('${post.likes}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline, size: 16, color: CommunityTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text('${_comments.length}', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
              const Divider(height: 28),
              Text(
                '评论 ${_comments.length}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (_comments.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text('还没有评论', style: TextStyle(fontSize: 12, color: CommunityTheme.textSecondary))),
                )
              else
                for (final comment in _comments) _CommentTile(comment: comment),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            8 + MediaQuery.of(context).viewInsets.bottom,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: CommunityTheme.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TInput(
                  controller: _commentController,
                  hintText: '友善交流，写下你的评论…',
                  inputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitComment(),
                ),
              ),
              const SizedBox(width: 8),
              TButton(
                child: const Text('发送'),
                size: TButtonSize.small,
                onPressed: _submitting ? null : _submitComment,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final CommunityComment comment;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TAvatar(
            size: TAvatarSize.small,
            child: Text(
              comment.authorName.isEmpty ? '?' : comment.authorName.characters.first,
              style: const TextStyle(fontSize: 10),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.authorName.isEmpty ? '匿名' : comment.authorName,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(comment.content, style: const TextStyle(fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
