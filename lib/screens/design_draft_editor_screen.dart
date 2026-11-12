import 'package:flutter/material.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../services/design_draft_service.dart';
import '../widgets/payload_graph_editor.dart';
import 'design_draft_list_screen.dart';

/// 设计稿编辑器
///
/// 在可视化编辑器中拖拽编排 Root / System / Block 三层 Payload 并填写参数，
/// 保存后得到一份完整的设计稿（即完整 Vibe），可用于创建 Loader 项目。
class DesignDraftEditorScreen extends StatefulWidget {
  /// 传入已有草稿进入编辑；为空则新建草稿
  final DesignDraft? draft;

  const DesignDraftEditorScreen({super.key, this.draft});

  @override
  State<DesignDraftEditorScreen> createState() =>
      _DesignDraftEditorScreenState();
}

class _DesignDraftEditorScreenState extends State<DesignDraftEditorScreen> {
  late final DesignDraft _draft;
  late final TextEditingController _nameController;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _draft = widget.draft ??
        DesignDraft(
          id: 'draft_${now.microsecondsSinceEpoch}',
          name: '',
          createdAt: now,
          updatedAt: now,
          root: RootPayloadInstance(specId: RootPayloadRegistry.defaultId),
          systems: [],
        );
    _nameController = TextEditingController(text: _draft.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    _draft.name = _nameController.text.trim().isEmpty
        ? '未命名设计稿'
        : _nameController.text.trim();
    try {
      await DesignDraftService.instance.save(_draft);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设计稿已保存'), backgroundColor: Colors.green),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e'), backgroundColor: Colors.red),
      );
      setState(() => _saving = false);
    }
  }

  /// 未保存时返回前确认
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('当前设计稿有未保存的编排修改，返回将丢失这些修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard() && mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _nameController,
            onChanged: (_) => _markDirty(),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: '设计稿名称',
              border: InputBorder.none,
              hintStyle: TextStyle(
                color: isDark ? Colors.white38 : Colors.black38,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: '我的设计稿',
              icon: const Icon(Icons.folder_copy_outlined),
              onPressed: () async {
                // 先保存再跳转列表，避免编排丢失
                if (_dirty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('有未保存修改，已为你先保存')),
                  );
                  _draft.name = _nameController.text.trim().isEmpty
                      ? '未命名设计稿'
                      : _nameController.text.trim();
                  await DesignDraftService.instance.save(_draft);
                }
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DesignDraftListScreen(),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // 顶部说明条
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: isDark
                  ? Colors.blueAccent.withValues(alpha: 0.08)
                  : const Color(0xFFE3F2FD),
              child: Text(
                '设计稿 = 完整 Vibe：用有向图编排端之间的跳转与依赖关系，创建 Loader 项目时选择「采用设计稿」即可让 AI 无感完成项目。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ),
            Expanded(
              child: PayloadGraphEditor(
                draft: _draft,
                onChanged: _markDirty,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
