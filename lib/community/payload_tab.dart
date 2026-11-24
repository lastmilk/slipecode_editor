import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../services/community_service.dart';
import '../services/custom_payload_service.dart';
import 'community_theme.dart';

/// 社区 Payload：浏览审核通过的包 / 我的发布
class PayloadTab extends StatefulWidget {
  const PayloadTab({super.key});

  @override
  State<PayloadTab> createState() => _PayloadTabState();
}

class _PayloadTabState extends State<PayloadTab> {
  final _custom = CustomPayloadService.instance;
  final _service = CommunityService.instance;

  List<CommunityPackage> _packages = [];
  List<CommunityPackage> _mine = [];
  bool _loading = true;
  bool _loadingMine = false;
  String? _kindFilter;
  bool _showMine = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _service.listPackages(kind: _kindFilter);
      if (!mounted) return;
      setState(() {
        _packages = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _packages = [];
        _loading = false;
      });
    }
  }

  Future<void> _loadMine() async {
    if (_loadingMine) return;
    setState(() => _loadingMine = true);
    try {
      final list = await _service.myPackages();
      if (!mounted) return;
      setState(() {
        _mine = list;
        _loadingMine = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mine = [];
        _loadingMine = false;
      });
    }
  }

  Future<void> _download(CommunityPackage pkg) async {
    try {
      final spec = await _service.download(pkg.id);
      String message;
      if (pkg.isRoot) {
        final imported = await _custom.importRoot(spec);
        message = '已导入「${imported.name}」到我的镜像';
      } else if (pkg.isSystem) {
        final imported = await _custom.importSystem(spec);
        message = '已导入「${imported.name}」到我的端';
      } else {
        final imported = await _custom.importBlock(spec);
        message = '已导入「${imported.name}」到我的功能模块';
      }
      if (!mounted) return;
      TToast.showSuccess(message, context: context);
      _load();
    } catch (e) {
      if (!mounted) return;
      TToast.showFail('$e', context: context);
    }
  }

  Future<void> _showPublishSheet() async {
    final roots = _custom.rootPayloads;
    final systems = _custom.systemPayloads;
    final blocks = _custom.blockPayloads;
    if (roots.isEmpty && systems.isEmpty && blocks.isEmpty) {
      TToast.showWarning('你还没有自定义 Payload，请先创建', context: context);
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
              child: Text(
                '选择要发布到社区的 Payload',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final spec in roots)
              ListTile(
                leading: Icon(spec.icon, color: Colors.deepPurple),
                title: Text(spec.name),
                subtitle: const Text('Root Payload'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _publish(
                    kind: 'root',
                    name: spec.name,
                    description: spec.description,
                    spec: spec.toMap(),
                  );
                },
              ),
            for (final spec in systems)
              ListTile(
                leading: Icon(spec.icon, color: Colors.teal),
                title: Text(spec.name),
                subtitle: const Text('System Payload'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _publish(
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
                  _publish(
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

  Future<void> _publish({
    required String kind,
    required String name,
    required String description,
    required Map<String, dynamic> spec,
    String readme = '',
  }) async {
    final controller = TextEditingController(text: description);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发布「$name」到社区'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('提交后需管理员审核，通过后社区可见。', style: TextStyle(fontSize: 11)),
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
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交审核'),
          ),
        ],
      ),
    );
    final desc = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;
    try {
      await _service.publish(
        kind: kind,
        name: name,
        description: desc,
        spec: spec,
        readme: readme,
      );
      if (!mounted) return;
      setState(() => _showMine = true);
      TToast.showSuccess('已提交审核，通过后会出现在社区', context: context);
      _loadMine();
    } catch (e) {
      if (!mounted) return;
      TToast.showFail('$e', context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              _chip('全部', _kindFilter == null, () {
                setState(() => _kindFilter = null);
                _load();
              }),
              const SizedBox(width: 6),
              _chip('端', _kindFilter == 'system', () {
                setState(() => _kindFilter = 'system');
                _load();
              }),
              const SizedBox(width: 6),
              _chip('模块', _kindFilter == 'block', () {
                setState(() => _kindFilter = 'block');
                _load();
              }),
              const SizedBox(width: 6),
              _chip('镜像', _kindFilter == 'root', () {
                setState(() => _kindFilter = 'root');
                _load();
              }),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() => _showMine = !_showMine);
                  if (_showMine) _loadMine();
                },
                child: Text(
                  _showMine ? '看社区' : '我的发布',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _showMine ? _loadMine : _load,
            child: _buildList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: TButton(
              child: const Text('发布 Payload'),
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              onPressed: _showPublishSheet,
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? CommunityTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? CommunityTheme.brand : CommunityTheme.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : CommunityTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final list = _showMine ? _mine : _packages;
    final loading = _showMine ? _loadingMine : _loading;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 90),
          TEmpty(emptyText: _showMine ? '还没有发布记录' : '暂无社区包'),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: list.length,
      itemBuilder: (context, index) => _PackageCard(
        pkg: list[index],
        mine: _showMine,
        onDownload: () => _download(list[index]),
      ),
    );
  }
}

class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.pkg,
    required this.mine,
    required this.onDownload,
  });

  final CommunityPackage pkg;
  final bool mine;
  final VoidCallback onDownload;

  String get _kindLabel {
    if (pkg.isRoot) return 'Root';
    if (pkg.isSystem) return 'System';
    return 'Block';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
              Text(
                pkg.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              TTag(
                _kindLabel,
                size: TTagSize.small,
                variant: TTagVariant.light,
              ),
              const Spacer(),
              if (mine) _statusTag(pkg.status),
            ],
          ),
          if (pkg.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              pkg.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: CommunityTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                pkg.authorName.isEmpty ? '匿名' : pkg.authorName,
                style: TextStyle(
                  fontSize: 11,
                  color: CommunityTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${pkg.downloads} 次下载',
                style: TextStyle(
                  fontSize: 11,
                  color: CommunityTheme.textSecondary,
                ),
              ),
              const Spacer(),
              if (!mine && pkg.status == 'approved')
                TButton(
                  child: const Text('导入'),
                  size: TButtonSize.extraSmall,
                  variant: TButtonVariant.outline,
                  onPressed: onDownload,
                ),
            ],
          ),
          if (mine && pkg.reviewNote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '审核备注：${pkg.reviewNote}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFD54941)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusTag(String status) {
    switch (status) {
      case 'approved':
        return TTag(
          '已通过',
          size: TTagSize.small,
          colorPreset: TTagColorPreset.success,
          variant: TTagVariant.light,
        );
      case 'rejected':
        return TTag(
          '已驳回',
          size: TTagSize.small,
          colorPreset: TTagColorPreset.danger,
          variant: TTagVariant.light,
        );
      default:
        return TTag(
          '待审核',
          size: TTagSize.small,
          colorPreset: TTagColorPreset.warning,
          variant: TTagVariant.light,
        );
    }
  }
}
