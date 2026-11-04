import 'package:flutter/material.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../services/design_draft_service.dart';
import 'create_loader_project_screen.dart';
import 'design_draft_editor_screen.dart';

/// 设计稿列表
///
/// 管理本机的全部设计稿：新建 / 编辑 / 删除 / 用设计稿创建 Loader 项目。
class DesignDraftListScreen extends StatefulWidget {
  const DesignDraftListScreen({super.key});

  @override
  State<DesignDraftListScreen> createState() => _DesignDraftListScreenState();
}

class _DesignDraftListScreenState extends State<DesignDraftListScreen> {
  List<DesignDraft> _drafts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await DesignDraftService.instance.list();
    if (!mounted) return;
    setState(() {
      _drafts = items;
      _loading = false;
    });
  }

  String _summaryOf(DesignDraft draft) {
    final root = RootPayloadRegistry.byId(draft.root.specId);
    final blockCount = draft.systems
        .fold<int>(0, (sum, s) => sum + s.blocks.length);
    return '${root.name} · ${draft.systems.length} 个端 · $blockCount 个模块';
  }

  static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _openEditor([DesignDraft? draft]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DesignDraftEditorScreen(draft: draft)),
    );
    _reload();
  }

  Future<void> _confirmDelete(DesignDraft draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除设计稿'),
        content: Text('确定删除设计稿「${draft.name}」吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await DesignDraftService.instance.delete(draft.id);
      _reload();
    }
  }

  Future<void> _createLoaderProject(DesignDraft draft) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateLoaderProjectScreen(initialDraft: draft),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('我的设计稿')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新建设计稿'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _drafts.isEmpty
              ? _buildEmpty(isDark)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                    itemCount: _drafts.length,
                    itemBuilder: (context, index) =>
                        _buildDraftCard(_drafts[index], isDark),
                  ),
                ),
    );
  }

  Widget _buildEmpty(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.design_services_outlined,
              size: 56, color: isDark ? Colors.white24 : Colors.black26),
          const SizedBox(height: 12),
          Text(
            '还没有设计稿\n点右下角「新建设计稿」开始编排 Payload',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDraftCard(DesignDraft draft, bool isDark) {
    final root = RootPayloadRegistry.byId(draft.root.specId);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? const Color(0xFF2D2D30) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openEditor(draft),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(root.icon, color: Colors.blueAccent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _summaryOf(draft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '更新于 ${_formatTime(draft.updatedAt)}',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white30 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (action) {
                  switch (action) {
                    case 'create':
                      _createLoaderProject(draft);
                    case 'edit':
                      _openEditor(draft);
                    case 'delete':
                      _confirmDelete(draft);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'create',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.rocket_launch_outlined, size: 20),
                      title: Text('用此设计稿创建 Loader 项目'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined, size: 20),
                      title: Text('编辑'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline,
                          size: 20, color: Colors.redAccent),
                      title: Text('删除',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
