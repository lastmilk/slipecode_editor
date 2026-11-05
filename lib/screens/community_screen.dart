import 'package:flutter/material.dart';

import '../services/community_service.dart';
import '../services/custom_payload_service.dart';
import 'custom_payload_manager_screen.dart';

/// Payload 社区
///
/// - 「社区包」：浏览审核通过的 System / Block Payload，一键下载导入本地
/// - 「我的发布」：查看自己提交的包与审核状态（待审核 / 已通过 / 已驳回）
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _custom = CustomPayloadService.instance;

  List<CommunityPackage> _packages = [];
  List<CommunityPackage> _mine = [];
  bool _loadingList = false;
  bool _loadingMine = false;
  String? _kindFilter;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() {
      if (_tab.index == 1) _loadMine();
    });
    _loadCommunity();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadCommunity() async {
    if (!CommunityService.instance.isConfigured) {
      if (mounted) {
        setState(() => _packages = []);
      }
      return;
    }
    setState(() => _loadingList = true);
    try {
      final list = await CommunityService.instance.listPackages(
        kind: _kindFilter,
      );
      if (!mounted) return;
      setState(() => _packages = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _packages = []);
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _loadMine() async {
    if (_loadingMine) return;
    if (!CommunityService.instance.isConfigured) {
      if (mounted) setState(() => _mine = []);
      return;
    }
    setState(() => _loadingMine = true);
    try {
      final list = await CommunityService.instance.myPackages();
      if (!mounted) return;
      setState(() => _mine = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _mine = []);
    } finally {
      if (mounted) setState(() => _loadingMine = false);
    }
  }

  Future<void> _download(CommunityPackage pkg) async {
    try {
      final spec = await CommunityService.instance.download(pkg.id);
      if (pkg.isSystem) {
        final imported = await _custom.importSystem(spec);
        if (!mounted) return;
        _toast('已导入「${imported.name}」到我的端，可在设计稿编排中使用');
      } else {
        final imported = await _custom.importBlock(spec);
        if (!mounted) return;
        _toast('已导入「${imported.name}」到我的功能模块');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('$e', isError: true);
    }
  }

  void _toast(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 发布
  // -------------------------------------------------------------------------

  Future<void> _showPublishSheet() async {
    final systems = _custom.systemPayloads;
    final blocks = _custom.blockPayloads;
    if (systems.isEmpty && blocks.isEmpty) {
      _toast('你还没有自定义 Payload，请先创建');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('选择要发布到社区的 Payload',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final spec in systems)
              ListTile(
                leading: Icon(spec.icon, color: Colors.teal),
                title: Text(spec.name),
                subtitle: const Text('System Payload'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _publishSpec(
                    kind: 'system',
                    name: spec.name,
                    description: spec.description,
                    spec: spec.toMap(),
                  );
                },
              ),
            for (final spec in blocks)
              ListTile(
                leading: Icon(spec.icon, color: Colors.orange),
                title: Text(spec.name),
                subtitle: const Text('Block Payload'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _publishSpec(
                    kind: 'block',
                    name: spec.name,
                    description: spec.description,
                    spec: spec.toMap(),
                    readme: spec.markdownTemplate,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _publishSpec({
    required String kind,
    required String name,
    required String description,
    required Map<String, dynamic> spec,
    String readme = '',
  }) async {
    final controller = TextEditingController(text: description);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发布「$name」到社区'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('提交后需管理员审核，通过后社区可见。',
                style: TextStyle(fontSize: 11)),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '简介',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交审核'),
          ),
        ],
      ),
    );
    final desc = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;
    try {
      await CommunityService.instance.publish(
        kind: kind,
        name: name,
        description: desc,
        spec: spec,
        readme: readme,
      );
      if (!mounted) return;
      _toast('已提交审核，通过后会出现在社区');
      _tab.animateTo(1);
      _loadMine();
    } catch (e) {
      if (!mounted) return;
      _toast('$e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payload 社区'),
        actions: [
          IconButton(
            tooltip: '我的 Payload',
            icon: const Icon(Icons.extension_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const CustomPayloadManagerScreen(),
                ),
              );
              if (!mounted) return;
              setState(() {});
              _loadMine();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '社区包'),
            Tab(text: '我的发布'),
          ],
          onTap: (index) {
            if (index == 1) _loadMine();
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showPublishSheet,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('发布 Payload'),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildCommunityTab(isDark),
          _buildMineTab(isDark),
        ],
      ),
    );
  }

  Widget _buildCommunityTab(bool isDark) {
    return RefreshIndicator(
      onRefresh: _loadCommunity,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (!CommunityService.instance.isConfigured)
            _notice('未配置账号后端，无法访问社区', isDark)
          else ...[
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('全部', style: TextStyle(fontSize: 12)),
                  selected: _kindFilter == null,
                  onSelected: (_) {
                    setState(() => _kindFilter = null);
                    _loadCommunity();
                  },
                ),
                ChoiceChip(
                  label: const Text('端 System', style: TextStyle(fontSize: 12)),
                  selected: _kindFilter == 'system',
                  onSelected: (_) {
                    setState(() => _kindFilter = 'system');
                    _loadCommunity();
                  },
                ),
                ChoiceChip(
                  label: const Text('模块 Block', style: TextStyle(fontSize: 12)),
                  selected: _kindFilter == 'block',
                  onSelected: (_) {
                    setState(() => _kindFilter = 'block');
                    _loadCommunity();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loadingList)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_packages.isEmpty)
              _notice('暂无社区包。审核通过的用户 Payload 会出现在这里。', isDark)
            else
              for (final pkg in _packages) _buildPackageCard(pkg, isDark),
          ],
        ],
      ),
    );
  }

  Widget _buildMineTab(bool isDark) {
    return RefreshIndicator(
      onRefresh: _loadMine,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (_loadingMine)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_mine.isEmpty)
            _notice('还没有发布记录。点击右下角「发布 Payload」把你自定义的端或模块提交到社区。',
                isDark)
          else
            for (final pkg in _mine) _buildPackageCard(pkg, isDark, mine: true),
        ],
      ),
    );
  }

  Widget _buildPackageCard(CommunityPackage pkg, bool isDark,
      {bool mine = false}) {
    final kindColor = pkg.isSystem ? Colors.teal : Colors.orange;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  pkg.isSystem ? Icons.widgets_outlined : Icons.extension_outlined,
                  size: 18,
                  color: kindColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pkg.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: kindColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    pkg.isSystem ? 'System' : 'Block',
                    style: TextStyle(fontSize: 10, color: kindColor),
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 6),
                  _statusTag(pkg.status),
                ],
              ],
            ),
            if (pkg.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                pkg.description,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.person_outline,
                    size: 13,
                    color: isDark ? Colors.white38 : Colors.black45),
                const SizedBox(width: 3),
                Text(
                  pkg.authorName.isEmpty ? '匿名' : pkg.authorName,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(Icons.download_outlined,
                    size: 13,
                    color: isDark ? Colors.white38 : Colors.black45),
                const SizedBox(width: 3),
                Text(
                  '${pkg.downloads}',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
                const Spacer(),
                if (!mine && pkg.status == 'approved')
                  TextButton.icon(
                    onPressed: () => _download(pkg),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('下载'),
                  ),
              ],
            ),
            if (mine && pkg.reviewNote.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '审核备注：${pkg.reviewNote}',
                style: const TextStyle(fontSize: 10, color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusTag(String status) {
    final Color color;
    final String text;
    switch (status) {
      case 'approved':
        color = Colors.green;
        text = '已通过';
        break;
      case 'rejected':
        color = Colors.red;
        text = '已驳回';
        break;
      default:
        color = Colors.orange;
        text = '待审核';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _notice(String text, bool isDark) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: isDark ? Colors.white38 : Colors.black45,
          ),
        ),
      );
}
