import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/docs_service.dart';

/// 使用文档列表页（只读，展示管理员发布的文档）
class DocsScreen extends StatefulWidget {
  const DocsScreen({super.key});

  @override
  State<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends State<DocsScreen> {
  List<DocSummary>? _docs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      appBar: AppBar(title: const Text('使用文档')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(isDark),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
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
                TextButton(onPressed: _load, child: const Text('重试')),
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
      separatorBuilder: (_, __) => const SizedBox(height: 8),
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

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(title: Text(widget.summary.title)),
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
