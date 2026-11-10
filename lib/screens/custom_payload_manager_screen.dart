import 'package:flutter/material.dart';

import '../payloads/loader/loader_payload.dart';
import '../services/community_service.dart';
import '../services/custom_payload_service.dart';
import 'custom_payload_editor_screen.dart';

/// 我的自定义 Payload 管理页
///
/// - System / Block 两类均可创建、编辑、删除
/// - 可一键发布到社区（进入审核队列）
/// - Root Payload 由官方维护，这里不提供创建入口
class CustomPayloadManagerScreen extends StatefulWidget {
  const CustomPayloadManagerScreen({super.key});

  @override
  State<CustomPayloadManagerScreen> createState() =>
      _CustomPayloadManagerScreenState();
}

class _CustomPayloadManagerScreenState
    extends State<CustomPayloadManagerScreen> {
  final _service = CustomPayloadService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  Future<void> _openEditor({
    String kind = 'system',
    RootPayloadSpec? root,
    SystemPayloadSpec? system,
    BlockPayloadSpec? block,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomPayloadEditorScreen(
          kind: kind,
          root: root,
          system: system,
          block: block,
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _deleteRoot(RootPayloadSpec spec) async {
    final ok = await _confirm('删除「${spec.name}」？');
    if (ok != true) return;
    await _service.removeRoot(spec.id);
  }

  Future<void> _deleteSystem(SystemPayloadSpec spec) async {
    final ok = await _confirm('删除「${spec.name}」？');
    if (ok != true) return;
    await _service.removeSystem(spec.id);
  }

  Future<void> _deleteBlock(BlockPayloadSpec spec) async {
    final ok = await _confirm('删除「${spec.name}」？');
    if (ok != true) return;
    await _service.removeBlock(spec.id);
  }

  Future<bool?> _confirm(String message) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认删除'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );

  Future<void> _publish({
    RootPayloadSpec? root,
    SystemPayloadSpec? system,
    BlockPayloadSpec? block,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController(
      text: root?.description ?? system?.description ?? block?.description ?? '',
    );
    final readmeController = TextEditingController(
      text: block?.markdownTemplate ?? '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发布「${root?.name ?? system?.name ?? block?.name ?? ''}」到社区'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '发布后需要管理员审核，通过后其他用户才能在社区下载。',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
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
              if (block != null) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: readmeController,
                  minLines: 6,
                  maxLines: 10,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '说明文档（Markdown）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
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
    final description = controller.text.trim();
    final readme = readmeController.text;
    controller.dispose();
    readmeController.dispose();
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      await CommunityService.instance.publish(
        kind: root != null
            ? 'root'
            : (system != null ? 'system' : 'block'),
        name: root?.name ?? system?.name ?? block?.name ?? '未命名 Payload',
        description: description,
        spec: root?.toMap() ?? system?.toMap() ?? block!.toMap(),
        readme: readme,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已提交审核，通过后会出现在社区'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败：$e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final roots = _service.rootPayloads;
    final systems = _service.systemPayloads;
    final blocks = _service.blockPayloads;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的 Payload'),
        actions: [
          TextButton.icon(
            onPressed: () => _openEditor(kind: 'root'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('镜像'),
          ),
          TextButton.icon(
            onPressed: () => _openEditor(kind: 'block'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('模块'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, left: 4),
            child: TextButton.icon(
              onPressed: () => _openEditor(kind: 'system'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('端'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.blueAccent.withValues(alpha: 0.08)
                  : const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Root（镜像）= 一组环境变量 + 一份 GitHub Actions workflow；'
              'System（端）与 Block（功能模块）也可以自由创建。'
              '自定义条目会直接出现在设计稿编排器中，也可发布到社区共享。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _sectionHeader('Root Payload（构建镜像）', roots.length, isDark),
          if (roots.isEmpty)
            _emptyHint('还没有自定义镜像，点击右上角「＋镜像」创建', isDark)
          else
            for (final spec in roots) _buildRootCard(spec, isDark),
          const SizedBox(height: 18),
          _sectionHeader('System Payload（端）', systems.length, isDark),
          if (systems.isEmpty)
            _emptyHint('还没有自定义的端，点击右上角「＋端」创建', isDark)
          else
            for (final spec in systems)
              _buildSystemCard(spec, isDark),
          const SizedBox(height: 18),
          _sectionHeader('Block Payload（功能模块）', blocks.length, isDark),
          if (blocks.isEmpty)
            _emptyHint('还没有自定义的功能模块，点击右上角「＋模块」创建', isDark)
          else
            for (final spec in blocks) _buildBlockCard(spec, isDark),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, int count, bool isDark) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                )),
            const SizedBox(width: 6),
            Text('$count',
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black45)),
          ],
        ),
      );

  Widget _emptyHint(String text, bool isDark) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white38 : Colors.black45)),
      );

  Widget _buildRootCard(RootPayloadSpec spec, bool isDark) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(spec.icon, color: Colors.deepPurple),
        title: Text(spec.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '${spec.buildEnvLabel} · ${spec.envVars.length} 个环境变量'
          '${spec.description.isEmpty ? '' : '\n${spec.description}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '发布到社区',
              icon: const Icon(Icons.cloud_upload_outlined, size: 20),
              onPressed: () => _publish(root: spec),
            ),
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _openEditor(kind: 'root', root: spec),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteRoot(spec),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemCard(SystemPayloadSpec spec, bool isDark) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(spec.icon, color: Colors.teal),
        title: Text(spec.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '${spec.defaultFolder}/ · ${spec.defaultLibrary}'
          '${spec.description.isEmpty ? '' : '\n${spec.description}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '发布到社区',
              icon: const Icon(Icons.cloud_upload_outlined, size: 20),
              onPressed: () => _publish(system: spec),
            ),
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _openEditor(kind: 'system', system: spec),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteSystem(spec),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlockCard(BlockPayloadSpec spec, bool isDark) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(spec.icon, color: Colors.orange),
        title: Text(spec.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '${spec.applicableSystems.isEmpty ? '所有端' : spec.applicableSystems.join(', ')}'
          '${spec.description.isEmpty ? '' : ' · ${spec.description}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '发布到社区',
              icon: const Icon(Icons.cloud_upload_outlined, size: 20),
              onPressed: () => _publish(block: spec),
            ),
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _openEditor(kind: 'block', block: spec),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteBlock(spec),
            ),
          ],
        ),
      ),
    );
  }
}
