import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../models/knowledge_entry.dart';
import '../providers/account_provider.dart';
import '../services/docs_service.dart';
import '../services/knowledge_service.dart';

/// 文档与知识库
///
/// - 「文档」：管理员发布的官方使用文档（只读，可复制到知识库）
/// - 「知识库」：用户私人的经验文档（本地保存 + 账号云同步）
class DocsScreen extends StatefulWidget {
  const DocsScreen({super.key});

  @override
  State<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends State<DocsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<DocSummary>? _docs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDocs();
    _initKnowledge();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDocs() async {
    try {
      final docs = await DocsService.instance.listDocs();
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _initKnowledge() async {
    await KnowledgeService.instance.ensureLoaded();
    await _syncKnowledge();
  }

  /// 登录状态下与账号云端同步知识库
  Future<void> _syncKnowledge() async {
    if (!mounted) return;
    final account = context.read<AccountProvider>();
    if (!account.isSignedIn) return;
    await KnowledgeService.instance.sync(account.token);
  }

  String _formatTime(String iso) {
    final time = DateTime.tryParse(iso);
    if (time == null) return '';
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('文档与知识库'),
        automaticallyImplyLeading: false,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '文档'),
            Tab(text: '知识库'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RefreshIndicator(
            onRefresh: _loadDocs,
            child: _buildDocsBody(isDark),
          ),
          _buildKnowledgeBody(isDark),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 官方文档
  // ---------------------------------------------------------------------------

  Widget _buildDocsBody(bool isDark) {
    final docs = _docs;
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(Icons.cloud_off,
                    size: 48, color: isDark ? Colors.white38 : Colors.black26),
                const SizedBox(height: 12),
                Text(
                  '加载失败：$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: isDark ? Colors.white54 : Colors.black45),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: _loadDocs, child: const Text('重试')),
              ],
            ),
          ),
        ],
      );
    }
    if (docs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (docs.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(Icons.menu_book_outlined,
                    size: 48, color: isDark ? Colors.white38 : Colors.black26),
                const SizedBox(height: 12),
                Text(
                  '暂无已发布的文档',
                  style: TextStyle(
                      color: isDark ? Colors.white54 : Colors.black45),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: docs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final doc = docs[index];
        return Card(
          elevation: 0,
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isDark ? Colors.white12 : Colors.black12,
            ),
          ),
          child: ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(doc.title),
            subtitle: Text('更新于 ${_formatTime(doc.updatedAt)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DocDetailScreen(summary: doc),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 私人知识库
  // ---------------------------------------------------------------------------

  Widget _buildKnowledgeBody(bool isDark) {
    return ListenableBuilder(
      listenable: KnowledgeService.instance,
      builder: (context, _) {
        final service = KnowledgeService.instance;
        final entries = service.items;
        final account = context.watch<AccountProvider>();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '私人知识库 · ${entries.length} 条',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'AI 可用 /exp 参考知识库经验，用 /expmod 写入经验'
                          '${account.isSignedIn ? ' · 已开启云同步' : ' · 登录后云同步'}',
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (account.isSignedIn)
                    IconButton(
                      tooltip: '同步知识库',
                      onPressed: service.syncing ? null : _syncKnowledge,
                      icon: service.syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_sync_outlined, size: 20),
                    ),
                  FilledButton.icon(
                    onPressed: () => _showKnowledgeEditor(),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 100),
                        Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.auto_stories_outlined,
                                size: 48,
                                color: isDark
                                    ? Colors.white30
                                    : Colors.black26,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '知识库还是空的\n在「文档」里看到好内容可以存入知识库，'
                                'AI 完成任务后也能用 /expmod 写入',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: isDark
                                      ? Colors.white54
                                      : Colors.black45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return Card(
                          elevation: 0,
                          color:
                              isDark ? const Color(0xFF1E1E1E) : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: isDark ? Colors.white12 : Colors.black12,
                            ),
                          ),
                          child: ListTile(
                            leading: Icon(
                              entry.source == 'ai'
                                  ? Icons.auto_awesome
                                  : entry.source == 'official'
                                      ? Icons.description_outlined
                                      : Icons.sticky_note_2_outlined,
                              color: entry.source == 'ai'
                                  ? Colors.purpleAccent
                                  : Colors.teal,
                            ),
                            title: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              entry.preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showKnowledgeDetail(entry),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 新建 / 编辑知识条目
  Future<void> _showKnowledgeEditor({KnowledgeEntry? entry}) async {
    final titleController = TextEditingController(text: entry?.title ?? '');
    final tagsController =
        TextEditingController(text: entry?.tags.join(', ') ?? '');
    final contentController = TextEditingController(text: entry?.content ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry == null ? '新建知识' : '编辑知识'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  autofocus: entry == null,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: tagsController,
                  decoration: const InputDecoration(
                    labelText: '标签（用逗号分隔）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: contentController,
                  minLines: 8,
                  maxLines: 16,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '内容（Markdown）',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (contentController.text.trim().isEmpty) return;
              Navigator.of(ctx).pop(true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await KnowledgeService.instance.upsert(
        id: entry?.id,
        title: titleController.text,
        content: contentController.text.trim(),
        tags: tagsController.text
            .split(RegExp(r'[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        source: entry?.source ?? 'manual',
        sourceId: entry?.sourceId ?? '',
      );
      await _syncKnowledge();
    }
    titleController.dispose();
    tagsController.dispose();
    contentController.dispose();
  }

  /// 查看知识条目
  Future<void> _showKnowledgeDetail(KnowledgeEntry entry) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showKnowledgeEditor(entry: entry);
                      },
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _deleteKnowledge(entry);
                      },
                    ),
                  ],
                ),
              ),
              if (entry.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final tag in entry.tags)
                        Chip(
                          label: Text(tag, style: const TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Expanded(
                child: Markdown(
                  data: entry.content,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      fontSize: 13,
                      height: 1.65,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteKnowledge(KnowledgeEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除知识'),
        content: Text('确定删除「${entry.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await KnowledgeService.instance.delete(entry.id);
      await _syncKnowledge();
    }
  }
}

/// 单篇文档详情（Markdown 渲染）
class DocDetailScreen extends StatefulWidget {
  final DocSummary summary;

  const DocDetailScreen({super.key, required this.summary});

  @override
  State<DocDetailScreen> createState() => _DocDetailScreenState();
}

class _DocDetailScreenState extends State<DocDetailScreen> {
  DocDetail? _doc;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await DocsService.instance.getDoc(widget.summary.id);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// 复制到私人知识库，并同步到云端
  Future<void> _saveToKnowledge() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    setState(() => _saving = true);
    try {
      await KnowledgeService.instance.importFromDoc(
        docId: doc.id,
        title: doc.title.isEmpty ? widget.summary.title : doc.title,
        content: doc.content,
      );
      if (!mounted) return;
      final account = context.read<AccountProvider>();
      if (account.isSignedIn) {
        await KnowledgeService.instance.sync(account.token);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已存入知识库'),
          backgroundColor: Colors.green,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.summary.title),
        actions: [
          IconButton(
            tooltip: '存入知识库',
            onPressed: doc == null || _saving ? null : _saveToKnowledge,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bookmark_add_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('加载失败：$_error'),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : doc == null
              ? const Center(child: CircularProgressIndicator())
              : Markdown(
                  data: doc.content,
                  padding: const EdgeInsets.all(20),
                  selectable: true,
                ),
    );
  }
}
