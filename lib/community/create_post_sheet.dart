import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../services/community_service.dart';
import 'community_theme.dart';

/// 打开发帖面板，成功发布返回 true
Future<bool?> showCreatePostSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _CreatePostSheet(),
  );
}

class _CreatePostSheet extends StatefulWidget {
  const _CreatePostSheet();

  @override
  State<_CreatePostSheet> createState() => _CreatePostSheetState();
}

class _CreatePostSheetState extends State<_CreatePostSheet> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  final _tags = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    final content = _content.text.trim();
    if (title.isEmpty || content.isEmpty) {
      setState(() => _error = '标题和正文都不能为空');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final tags = _tags.text
          .split(RegExp(r'[,，\s]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final result = await CommunityService.instance.createPost(
        title: title,
        content: content,
        tags: tags,
      );
      if (!mounted) return;
      TToast.showSuccess(
        result.needReview ? '首帖已提交审核，通过后可见' : '发布成功',
        context: context,
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: BoxDecoration(
          color: CommunityTheme.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '发布帖子',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7E6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '首次发帖需要管理员审核；请勿发布广告、违法、侵权或攻击性内容。',
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              TInput(
                controller: _title,
                hintText: '标题（最多 80 字）',
                maxLength: 80,
              ),
              const SizedBox(height: 10),
              TTextarea(
                controller: _content,
                hintText: '正文，支持 Markdown。请描述清楚问题或分享内容。',
                maxLines: 10,
                minLines: 6,
              ),
              const SizedBox(height: 10),
              TInput(controller: _tags, hintText: '标签（可选，用逗号分隔，最多 5 个）'),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _error,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFD54941),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: TButton(
                  child: Text(_submitting ? '提交中…' : '提交'),
                  onPressed: _submitting ? null : _submit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
