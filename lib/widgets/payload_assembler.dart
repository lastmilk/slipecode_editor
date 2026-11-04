import 'package:flutter/material.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';

/// Payload 可视化编排器
///
/// 三层组装视图：
/// 1. 顶部选择 Root Payload（项目初始环境）
/// 2. 中部画布：把 System Payload 卡片拖入 / 点按加入，可拖拽排序；
///    每个 System 卡片本身是一个 DragTarget，可接收 Block Payload
/// 3. 底部 Block 仓库：拖拽或点按（选择目标端）加入功能模块
///
/// 任何卡片点击「参数」都会弹出按参数定义自动生成的表单。
class PayloadAssemblerView extends StatefulWidget {
  /// 被编排的设计稿（直接原地修改，修改后触发 [onChanged]）
  final DesignDraft draft;
  final VoidCallback onChanged;

  const PayloadAssemblerView({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  @override
  State<PayloadAssemblerView> createState() => _PayloadAssemblerViewState();
}

class _PayloadAssemblerViewState extends State<PayloadAssemblerView> {
  DesignDraft get draft => widget.draft;

  void _mutate(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  // ---------------------------------------------------------------------------
  // 编排操作
  // ---------------------------------------------------------------------------

  void _selectRoot(String specId) => _mutate(() {
        draft.root.specId = specId;
        draft.root.params = {};
      });

  void _addSystem(String specId) => _mutate(() {
        draft.systems.add(SystemPayloadInstance(specId: specId));
      });

  void _removeSystem(int index) => _mutate(() {
        draft.systems.removeAt(index);
      });

  void _reorderSystems(int oldIndex, int newIndex) => _mutate(() {
        if (newIndex > oldIndex) newIndex--;
        final item = draft.systems.removeAt(oldIndex);
        draft.systems.insert(newIndex, item);
      });

  void _addBlock(int systemIndex, String blockId) => _mutate(() {
        final blocks = draft.systems[systemIndex].blocks;
        if (blocks.any((b) => b.specId == blockId)) return; // 每端同模块只加一次
        blocks.add(BlockPayloadInstance(specId: blockId));
      });

  void _removeBlock(int systemIndex, int blockIndex) => _mutate(() {
        draft.systems[systemIndex].blocks.removeAt(blockIndex);
      });

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rootSpec = RootPayloadRegistry.byId(draft.root.specId);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle('① Root Payload · 项目初始环境', isDark),
        const SizedBox(height: 8),
        _buildRootRow(rootSpec, isDark),
        const SizedBox(height: 20),
        _sectionTitle('② System Payload · 端的编排', isDark),
        const SizedBox(height: 4),
        _hint('把下方的「端」拖入画布（或点按添加），长按卡片左侧手柄可排序', isDark),
        const SizedBox(height: 8),
        _buildSystemPalette(isDark),
        const SizedBox(height: 10),
        _buildSystemCanvas(isDark),
        const SizedBox(height: 20),
        _sectionTitle('③ Block Payload · 功能模块仓库', isDark),
        const SizedBox(height: 4),
        _hint('拖拽模块到某个端的卡片上，或点按模块选择目标端', isDark),
        const SizedBox(height: 8),
        _buildBlockPalette(isDark),
      ],
    );
  }

  Widget _sectionTitle(String text, bool isDark) => Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      );

  Widget _hint(String text, bool isDark) => Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? Colors.white38 : Colors.black45,
        ),
      );

  // --- Root -----------------------------------------------------------------

  Widget _buildRootRow(RootPayloadSpec selected, bool isDark) {
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: RootPayloadRegistry.all.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final spec = RootPayloadRegistry.all[index];
          final isSelected = spec.id == selected.id;
          return GestureDetector(
            onTap: () => _selectRoot(spec.id),
            child: Container(
              width: 190,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2D2D30) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? Colors.blueAccent
                      : (isDark
                          ? const Color(0xFF3C3C3C)
                          : const Color(0xFFE0E4E8)),
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(spec.icon,
                          size: 18,
                          color: isSelected
                              ? Colors.blueAccent
                              : (isDark ? Colors.white70 : Colors.black54)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          spec.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isSelected)
                        InkWell(
                          onTap: () => PayloadParamsSheet.show(
                            context,
                            title: '${spec.name} · 参数',
                            defs: spec.params,
                            values: draft.root.params,
                          ),
                          child: const Icon(Icons.tune,
                              size: 18, color: Colors.blueAccent),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '构建环境：${spec.buildEnvLabel}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(
                      spec.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- System palette ---------------------------------------------------------

  Widget _buildSystemPalette(bool isDark) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: SystemPayloadRegistry.all.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final spec = SystemPayloadRegistry.all[index];
          final chip = _paletteChip(
            icon: spec.icon,
            label: spec.name,
            color: Colors.teal,
            isDark: isDark,
            onTap: () => _addSystem(spec.id),
          );
          return Draggable<String>(
            data: 'system:${spec.id}',
            feedback: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10),
              child: _paletteChip(
                icon: spec.icon,
                label: spec.name,
                color: Colors.teal,
                isDark: isDark,
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: chip),
            child: chip,
          );
        },
      ),
    );
  }

  // --- System canvas ----------------------------------------------------------

  Widget _buildSystemCanvas(bool isDark) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data.startsWith('system:'),
      onAcceptWithDetails: (details) =>
          _addSystem(details.data.substring('system:'.length)),
      builder: (context, candidate, _) {
        final highlight = candidate.isNotEmpty;
        if (draft.systems.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlight
                    ? Colors.blueAccent
                    : (isDark ? Colors.white24 : Colors.black26),
                style: BorderStyle.solid,
              ),
              color: highlight
                  ? Colors.blueAccent.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: Center(
              child: Text(
                '拖拽或点按上方卡片，把「端」添加到这里',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: highlight
                  ? Colors.blueAccent
                  : (isDark
                      ? const Color(0xFF3C3C3C)
                      : const Color(0xFFE0E4E8)),
            ),
          ),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: draft.systems.length,
            onReorder: _reorderSystems,
            itemBuilder: (context, index) =>
                _buildSystemCard(index, isDark, key: ValueKey('sys_$index'
                    '_${draft.systems[index].specId}')),
          ),
        );
      },
    );
  }

  Widget _buildSystemCard(int index, bool isDark, {required Key key}) {
    final instance = draft.systems[index];
    final spec = SystemPayloadRegistry.byId(instance.specId);
    final folder = instance.params['folder']?.trim().isNotEmpty == true
        ? instance.params['folder']!
        : spec.defaultFolder;
    final library = instance.params['library'] ?? spec.defaultLibrary;

    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          if (!details.data.startsWith('block:')) return false;
          final block =
              BlockPayloadRegistry.byId(details.data.substring(6));
          return block.appliesTo(spec.id) &&
              !instance.blocks.any((b) => b.specId == block.id);
        },
        onAcceptWithDetails: (details) =>
            _addBlock(index, details.data.substring(6)),
        builder: (context, candidate, _) {
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: candidate.isNotEmpty
                    ? Colors.orange
                    : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: Icon(Icons.drag_indicator,
                          size: 18,
                          color:
                              isDark ? Colors.white24 : Colors.black26),
                    ),
                    Icon(spec.icon, size: 18, color: Colors.teal),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        spec.name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '$folder/ · $library',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.tune, size: 17),
                      tooltip: '参数',
                      onPressed: () => PayloadParamsSheet.show(
                        context,
                        title: '${spec.name} · 参数',
                        defs: spec.params,
                        values: instance.params,
                        onChanged: widget.onChanged,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 17),
                      tooltip: '移除',
                      onPressed: () => _removeSystem(index),
                    ),
                  ],
                ),
                if (instance.blocks.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < instance.blocks.length; i++)
                        _blockChip(index, i, isDark),
                    ],
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 24),
                    child: Text(
                      candidate.isNotEmpty ? '松手添加该模块' : '拖入 Block Payload 添加功能模块',
                      style: TextStyle(
                        fontSize: 10,
                        color: candidate.isNotEmpty
                            ? Colors.orange
                            : (isDark ? Colors.white24 : Colors.black38),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _blockChip(int systemIndex, int blockIndex, bool isDark) {
    final instance = draft.systems[systemIndex].blocks[blockIndex];
    final spec = BlockPayloadRegistry.byId(instance.specId);
    return InputChip(
      avatar: Icon(spec.icon, size: 14, color: Colors.orange),
      label: Text(spec.name, style: const TextStyle(fontSize: 11)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      onPressed: () => PayloadParamsSheet.show(
        context,
        title: '${spec.name} · 参数',
        defs: spec.params,
        values: instance.params,
        onChanged: widget.onChanged,
      ),
      onDeleted: () => _removeBlock(systemIndex, blockIndex),
      deleteIcon: const Icon(Icons.close, size: 14),
      backgroundColor: isDark ? const Color(0xFF3A3A3D) : const Color(0xFFFFF4E5),
    );
  }

  // --- Block palette ----------------------------------------------------------

  Widget _buildBlockPalette(bool isDark) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final spec in BlockPayloadRegistry.all)
          Draggable<String>(
            data: 'block:${spec.id}',
            feedback: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10),
              child: _paletteChip(
                icon: spec.icon,
                label: spec.name,
                color: Colors.orange,
                isDark: isDark,
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.35,
              child: _paletteChip(
                icon: spec.icon,
                label: spec.name,
                color: Colors.orange,
                isDark: isDark,
              ),
            ),
            child: _paletteChip(
              icon: spec.icon,
              label: spec.name,
              color: Colors.orange,
              isDark: isDark,
              onTap: () => _pickTargetSystemFor(spec),
            ),
          ),
      ],
    );
  }

  Widget _paletteChip({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2D2D30) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// 点按 Block 时选择目标端
  void _pickTargetSystemFor(BlockPayloadSpec spec) {
    final candidates = <int>[];
    for (var i = 0; i < draft.systems.length; i++) {
      final sys = draft.systems[i];
      if (spec.appliesTo(sys.specId) &&
          !sys.blocks.any((b) => b.specId == spec.id)) {
        candidates.add(i);
      }
    }
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(draft.systems.isEmpty
              ? '请先在画布中添加一个「端」'
              : '所有端都已包含「${spec.name}」或不适用'),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('把「${spec.name}」加入：',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final i in candidates)
              ListTile(
                leading:
                    Icon(SystemPayloadRegistry.byId(draft.systems[i].specId).icon),
                title:
                    Text(SystemPayloadRegistry.byId(draft.systems[i].specId).name),
                subtitle: Text('${draft.systems[i].folder}/'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addBlock(i, spec.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 按参数定义自动生成的表单（底部弹层）
class PayloadParamsSheet extends StatefulWidget {
  final String title;
  final List<PayloadParamDef> defs;
  final Map<String, String> values;
  final VoidCallback? onChanged;

  const PayloadParamsSheet({
    super.key,
    required this.title,
    required this.defs,
    required this.values,
    this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required List<PayloadParamDef> defs,
    required Map<String, String> values,
    VoidCallback? onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: PayloadParamsSheet(
          title: title,
          defs: defs,
          values: values,
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  State<PayloadParamsSheet> createState() => _PayloadParamsSheetState();
}

class _PayloadParamsSheetState extends State<PayloadParamsSheet> {
  String _valueOf(PayloadParamDef def) =>
      widget.values[def.key] ?? def.defaultValue;

  void _set(PayloadParamDef def, String value) {
    setState(() => widget.values[def.key] = value);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (widget.defs.isEmpty)
              const Text('该 Payload 无可配置参数',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            for (final def in widget.defs) _buildField(def),
          ],
        ),
      ),
    );
  }

  Widget _buildField(PayloadParamDef def) {
    switch (def.type) {
      case PayloadParamType.bool:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          subtitle: def.hint.isEmpty
              ? null
              : Text(def.hint, style: const TextStyle(fontSize: 11)),
          value: _valueOf(def) == 'true',
          onChanged: (v) => _set(def, v ? 'true' : 'false'),
        );
      case PayloadParamType.select:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            initialValue:
                def.options.contains(_valueOf(def)) ? _valueOf(def) : null,
            decoration: InputDecoration(
              labelText: def.label,
              helperText: def.hint.isEmpty ? null : def.hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: def.options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) _set(def, v);
            },
          ),
        );
      case PayloadParamType.multiSelect:
        final selected = _valueOf(def)
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(def.label, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in def.options)
                    FilterChip(
                      label:
                          Text(option, style: const TextStyle(fontSize: 12)),
                      selected: selected.contains(option),
                      onSelected: (v) {
                        if (v) {
                          selected.add(option);
                        } else {
                          selected.remove(option);
                        }
                        _set(def, selected.join(','));
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      case PayloadParamType.text:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            initialValue: _valueOf(def),
            decoration: InputDecoration(
              labelText: def.label,
              hintText: def.hint.isEmpty ? null : def.hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _set(def, v),
          ),
        );
    }
  }
}
