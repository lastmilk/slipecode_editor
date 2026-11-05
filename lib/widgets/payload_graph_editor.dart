import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../screens/custom_payload_editor_screen.dart';
import 'payload_assembler.dart';

/// 节点卡片宽度（画布坐标系）
const double _kNodeWidth = 240;

/// 节点卡片高度估算（用于计算连线端点）
double nodeCardHeight(SystemPayloadInstance sys) {
  final rows = sys.blocks.isEmpty ? 1 : (sys.blocks.length / 2).ceil();
  return 92.0 + rows * 40.0;
}

/// 有向图编排器
///
/// 新版设计稿不再使用列表排序，而是用有向图表达真实项目中的
/// 「页面跳转」与「依赖」关系：
/// - 拖拽节点卡片可自由摆放；
/// - 开启「连线模式」后先点起点再点终点即可创建一条有向边；
/// - 连线类型分为「跳转（navigate）」与「依赖（depend）」；
/// - 关系列表支持修改类型与删除。
class PayloadGraphEditor extends StatefulWidget {
  final DesignDraft draft;
  final VoidCallback onChanged;

  const PayloadGraphEditor({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  @override
  State<PayloadGraphEditor> createState() => _PayloadGraphEditorState();
}

class _PayloadGraphEditorState extends State<PayloadGraphEditor> {
  DesignDraft get draft => widget.draft;

  bool _linkMode = false;
  String? _linkSource;
  DesignEdgeKind _linkKind = DesignEdgeKind.navigate;

  void _mutate(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  double get _canvasWidth => math.max(
        900.0,
        draft.systems.fold<double>(
          0.0,
          (value, sys) => math.max(value, sys.x + _kNodeWidth + 80),
        ),
      );

  double get _canvasHeight => math.max(
        620.0,
        draft.systems.fold<double>(
          0.0,
          (value, sys) => math.max(value, sys.y + nodeCardHeight(sys) + 80),
        ),
      );

  // -------------------------------------------------------------------------
  // 编排操作
  // -------------------------------------------------------------------------

  void _selectRoot(String specId) => _mutate(() {
        draft.root.specId = specId;
        draft.root.params = {};
      });

  void _addSystem(String specId) {
    final index = draft.systems.length;
    _mutate(() {
      draft.systems.add(
        SystemPayloadInstance(
          specId: specId,
          nodeId: 'node_${DateTime.now().microsecondsSinceEpoch}',
          x: 40.0 + (index % 3) * 280.0,
          y: 40.0 + (index ~/ 3) * 220.0,
        ),
      );
    });
  }

  void _removeSystem(SystemPayloadInstance instance) {
    _mutate(() {
      draft.systems.remove(instance);
      draft.edges.removeWhere(
        (e) => e.fromNodeId == instance.nodeId || e.toNodeId == instance.nodeId,
      );
    });
    if (_linkSource == instance.nodeId) {
      setState(() => _linkSource = null);
    }
  }

  void _addBlock(SystemPayloadInstance instance, String blockId) {
    if (instance.blocks.any((b) => b.specId == blockId)) return;
    _mutate(() => instance.blocks.add(BlockPayloadInstance(specId: blockId)));
  }

  void _removeBlock(SystemPayloadInstance instance, int index) =>
      _mutate(() => instance.blocks.removeAt(index));

  void _handleNodeTap(SystemPayloadInstance instance) {
    if (!_linkMode) return;
    if (_linkSource == null) {
      setState(() => _linkSource = instance.nodeId);
      return;
    }
    if (_linkSource == instance.nodeId) {
      setState(() => _linkSource = null);
      return;
    }
    final from = _linkSource!;
    setState(() => _linkSource = null);
    _connect(from, instance.nodeId);
  }

  void _connect(String fromId, String toId) {
    if (fromId == toId) return;
    final exists = draft.edges.any(
      (e) => e.fromNodeId == fromId && e.toNodeId == toId,
    );
    if (exists) {
      _toast('这两个端之间已存在连线');
      return;
    }
    _mutate(() {
      draft.edges.add(
        DesignEdge(
          id: 'edge_${DateTime.now().microsecondsSinceEpoch}',
          fromNodeId: fromId,
          toNodeId: toId,
          kind: _linkKind,
        ),
      );
    });
  }

  void _toggleLinkMode() {
    setState(() {
      _linkMode = !_linkMode;
      _linkSource = null;
    });
    if (_linkMode) {
      _toast('连线模式：先点选起点端，再点选终点端');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  String _nodeName(String nodeId) {
    final node = draft.nodeById(nodeId);
    if (node == null) return '已删除的端';
    return SystemPayloadRegistry.byId(node.specId).name;
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        _buildRootBar(isDark),
        _buildToolbar(isDark),
        Expanded(child: _buildCanvas(isDark)),
        _buildSystemPalette(isDark),
      ],
    );
  }

  Widget _buildRootBar(bool isDark) {
    final rootSpec = RootPayloadRegistry.byId(draft.root.specId);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Row(
        children: [
          Icon(rootSpec.icon, size: 18, color: Colors.blueAccent),
          const SizedBox(width: 8),
          Text('Root',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
              )),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: rootSpec.id,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                items: [
                  for (final spec in RootPayloadRegistry.all)
                    DropdownMenuItem(
                      value: spec.id,
                      child: Text('${spec.name} · ${spec.buildEnvLabel}'),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) _selectRoot(v);
                },
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Root 参数',
            icon: const Icon(Icons.tune, size: 18),
            onPressed: () => PayloadParamsSheet.show(
              context,
              title: '${rootSpec.name} · 参数',
              defs: rootSpec.params,
              values: draft.root.params,
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
      child: Row(
        children: [
          Tooltip(
            message: '开启后：先点起点端，再点终点端，即可创建一条有向边',
            child: FilterChip(
              avatar: Icon(
                _linkMode ? Icons.link : Icons.link_off,
                size: 16,
                color: _linkMode ? Colors.orange : Colors.blueAccent,
              ),
              label: Text('连线模式', style: const TextStyle(fontSize: 12)),
              selected: _linkMode,
              onSelected: (_) => _toggleLinkMode(),
            ),
          ),
          const SizedBox(width: 8),
          if (_linkMode) ...[
            for (final kind in DesignEdgeKind.values)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  label: Text(
                    kind.label,
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: _linkKind == kind,
                  onSelected: (_) => setState(() => _linkKind = kind),
                ),
              ),
            if (_linkSource != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '起点：${_nodeName(_linkSource!)}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.orange),
                ),
              ),
          ],
          const Spacer(),
          Text(
            '${draft.systems.length} 端 · ${draft.edges.length} 关系',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关系列表（${draft.edges.length}）',
            icon: const Icon(Icons.account_tree_outlined, size: 20),
            onPressed: _showRelations,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '添加自定义端',
            icon: const Icon(Icons.add_box_outlined, size: 20),
            onPressed: _createCustomSystem,
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252527) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: _canvasWidth,
            height: _canvasHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _EdgePainter(
                      draft: draft,
                      isDark: isDark,
                      highlightNodeId: _linkSource,
                    ),
                  ),
                ),
                if (draft.systems.isEmpty)
                  Positioned(
                    left: 24,
                    top: 24,
                    child: Text(
                      '画布还是空的：点击下方「端」添加节点，\n'
                      '然后开启「连线模式」建立跳转 / 依赖关系。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ),
                for (final sys in draft.systems) _buildNode(sys, isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNode(SystemPayloadInstance sys, bool isDark) {
    final spec = SystemPayloadRegistry.byId(sys.specId);
    final folder = sys.params['folder']?.trim().isNotEmpty == true
        ? sys.params['folder']!
        : spec.defaultFolder;
    final library = sys.params['library'] ?? spec.defaultLibrary;
    final isSource = _linkSource == sys.nodeId;

    return Positioned(
      left: sys.x,
      top: sys.y,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _handleNodeTap(sys),
        onPanUpdate: _linkMode
            ? null
            : (details) {
                setState(() {
                  sys.x = math.max(0.0, sys.x + details.delta.dx);
                  sys.y = math.max(0.0, sys.y + details.delta.dy);
                });
                widget.onChanged();
              },
        child: Container(
          width: _kNodeWidth,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D30) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSource
                  ? Colors.orange
                  : (_linkMode
                      ? Colors.blueAccent.withValues(alpha: 0.6)
                      : (isDark
                          ? const Color(0xFF3C3C3C)
                          : const Color(0xFFE0E4E8))),
              width: isSource ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
                child: Row(
                  children: [
                    Icon(spec.icon, size: 18, color: Colors.teal),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        spec.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 26, minHeight: 26),
                      tooltip: '参数',
                      icon: const Icon(Icons.tune, size: 15),
                      onPressed: () => PayloadParamsSheet.show(
                        context,
                        title: '${spec.name} · 参数',
                        defs: spec.params,
                        values: sys.params,
                        onChanged: widget.onChanged,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 26, minHeight: 26),
                      tooltip: '移除该端',
                      icon: const Icon(Icons.close, size: 15),
                      onPressed: () => _removeSystem(sys),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
                child: Text(
                  '$folder/ · $library',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (var i = 0; i < sys.blocks.length; i++)
                      _blockChip(sys, i, isDark),
                    InkWell(
                      onTap: () => _pickBlock(sys),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                            style: BorderStyle.solid,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 13, color: Colors.orange),
                            SizedBox(width: 2),
                            Text('模块',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.orange)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blockChip(SystemPayloadInstance sys, int index, bool isDark) {
    final instance = sys.blocks[index];
    final spec = BlockPayloadRegistry.byId(instance.specId);
    return InputChip(
      avatar: Icon(spec.icon, size: 12, color: Colors.orange),
      label: Text(spec.name, style: const TextStyle(fontSize: 10)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      onPressed: () => PayloadParamsSheet.show(
        context,
        title: '${spec.name} · 参数',
        defs: spec.params,
        values: instance.params,
        onChanged: widget.onChanged,
      ),
      onDeleted: () => _removeBlock(sys, index),
      deleteIcon: const Icon(Icons.close, size: 12),
      backgroundColor:
          isDark ? const Color(0xFF3A3A3D) : const Color(0xFFFFF4E5),
    );
  }

  Widget _buildSystemPalette(bool isDark) {
    return SizedBox(
      height: 58,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        scrollDirection: Axis.horizontal,
        children: [
          for (final spec in SystemPayloadRegistry.all)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: Icon(spec.icon, size: 15, color: Colors.teal),
                label: Text(spec.name, style: const TextStyle(fontSize: 12)),
                tooltip: '添加「${spec.name}」端',
                onPressed: () => _addSystem(spec.id),
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 15, color: Colors.blueAccent),
            label: const Text('自定义端', style: TextStyle(fontSize: 12)),
            tooltip: '创建自定义 System Payload',
            onPressed: _createCustomSystem,
          ),
        ],
      ),
    );
  }

  Future<void> _createCustomSystem() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const CustomPayloadEditorScreen(kind: 'system'),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _pickBlock(SystemPayloadInstance sys) async {
    final spec = SystemPayloadRegistry.byId(sys.specId);
    final candidates = BlockPayloadRegistry.forSystem(spec.id)
        .where((b) => !sys.blocks.any((e) => e.specId == b.id))
        .toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '为「${spec.name}」添加功能模块',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const CustomPayloadEditorScreen(kind: 'block'),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('自定义模块'),
                  ),
                ],
              ),
            ),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '该端已包含所有可用模块，或还没有适用模块',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final block in candidates)
                      ListTile(
                        leading: Icon(block.icon, color: Colors.orange),
                        title: Text(block.name),
                        subtitle: Text(block.description,
                            style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _addBlock(sys, block.id);
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRelations() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              if (draft.edges.isEmpty) {
                return Center(
                  child: Text(
                    '还没有关系。开启「连线模式」后点选两个端即可创建。',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                );
              }
              return ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Text('页面跳转与依赖关系',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  for (final edge in draft.edges)
                    ListTile(
                      leading: Icon(
                        edge.kind == DesignEdgeKind.navigate
                            ? Icons.arrow_forward
                            : Icons.account_tree_outlined,
                        color: edge.kind == DesignEdgeKind.navigate
                            ? Colors.blueAccent
                            : Colors.orange,
                      ),
                      title: Text(
                        '${_nodeName(edge.fromNodeId)} → '
                        '${_nodeName(edge.toNodeId)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        edge.label.isEmpty
                            ? edge.kind.arrowHint
                            : '${edge.kind.label}：${edge.label}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<DesignEdgeKind>(
                            tooltip: '切换类型',
                            icon: const Icon(Icons.swap_horiz, size: 20),
                            onSelected: (kind) {
                              setState(() {
                                edge.kind = kind;
                              });
                              widget.onChanged();
                              setSheetState(() {});
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: DesignEdgeKind.navigate,
                                child: Text('改为跳转'),
                              ),
                              const PopupMenuItem(
                                value: DesignEdgeKind.depend,
                                child: Text('改为依赖'),
                              ),
                            ],
                          ),
                          IconButton(
                            tooltip: '删除关系',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () {
                              setState(() => draft.edges.remove(edge));
                              widget.onChanged();
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 画布连线绘制（有向箭头 + 关系标签）
class _EdgePainter extends CustomPainter {
  final DesignDraft draft;
  final bool isDark;
  final String? highlightNodeId;

  _EdgePainter({
    required this.draft,
    required this.isDark,
    this.highlightNodeId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in draft.edges) {
      final from = draft.nodeById(edge.fromNodeId);
      final to = draft.nodeById(edge.toNodeId);
      if (from == null || to == null) continue;

      final fromRect = Rect.fromLTWH(
          from.x, from.y, _kNodeWidth, nodeCardHeight(from));
      final toRect = Rect.fromLTWH(to.x, to.y, _kNodeWidth, nodeCardHeight(to));
      final start = _boundaryPoint(fromRect, toRect.center);
      final end = _boundaryPoint(toRect, fromRect.center);

      final color = edge.kind == DesignEdgeKind.navigate
          ? Colors.blueAccent
          : Colors.orange;
      final highlight = highlightNodeId != null &&
          (edge.fromNodeId == highlightNodeId ||
              edge.toNodeId == highlightNodeId);
      final paint = Paint()
        ..color = highlight ? color : color.withValues(alpha: 0.72)
        ..strokeWidth = highlight ? 2.2 : 1.4
        ..style = PaintingStyle.stroke;

      // 轻微弧线，避免多条边互相重叠时难以分辨
      final mid = Offset(
        (start.dx + end.dx) / 2,
        (start.dy + end.dy) / 2,
      );
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final length = math.sqrt(dx * dx + dy * dy);
      final bow = length < 1 ? 0.0 : 18.0;
      final control = Offset(
        mid.dx - dy / (length == 0 ? 1 : length) * bow,
        mid.dy + dx / (length == 0 ? 1 : length) * bow,
      );
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);

      // 箭头
      final direction = end - control;
      final angle = math.atan2(direction.dy, direction.dx);
      const arrowLength = 9.0;
      const arrowAngle = math.pi / 7;
      final arrowPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      final arrowPath = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(
          end.dx - arrowLength * math.cos(angle - arrowAngle),
          end.dy - arrowLength * math.sin(angle - arrowAngle),
        )
        ..lineTo(
          end.dx - arrowLength * math.cos(angle + arrowAngle),
          end.dy - arrowLength * math.sin(angle + arrowAngle),
        )
        ..close();
      canvas.drawPath(arrowPath, arrowPaint);

      // 关系标签
      final text = edge.label.isEmpty ? edge.kind.label : edge.label;
      final span = TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 9.5,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      );
      final painter = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
      )..layout();
      final labelCenter = Offset(
        0.25 * start.dx + 0.5 * control.dx + 0.25 * end.dx,
        0.25 * start.dy + 0.5 * control.dy + 0.25 * end.dy,
      );
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: labelCenter,
          width: painter.width + 10,
          height: painter.height + 6,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = isDark
              ? const Color(0xFF252527)
              : const Color(0xFFF8FAFC),
      );
      painter.paint(
        canvas,
        labelCenter - Offset(painter.width / 2, painter.height / 2),
      );
    }
  }

  /// 计算从矩形中心指向 target 的边界交点
  Offset _boundaryPoint(Rect rect, Offset target) {
    final center = rect.center;
    final dx = target.dx - center.dx;
    final dy = target.dy - center.dy;
    if (dx.abs() < 0.01 && dy.abs() < 0.01) return center;
    final scaleX = dx.abs() < 0.01 ? double.infinity : (rect.width / 2) / dx.abs();
    final scaleY =
        dy.abs() < 0.01 ? double.infinity : (rect.height / 2) / dy.abs();
    final t = math.min(scaleX, scaleY);
    return Offset(center.dx + dx * t, center.dy + dy * t);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => true;
}
