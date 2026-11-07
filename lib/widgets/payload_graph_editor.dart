import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../screens/custom_payload_editor_screen.dart';
import 'payload_assembler.dart';

/// 节点卡片宽度（画布坐标系）
const double _kNodeWidth = 240;

/// 节点内部布局常量（用于计算引脚坐标）
const double _kHeaderHeight = 44.0; // 图标 + 名称 + 按钮行
const double _kSubtitleHeight = 18.0; // folder/library 副标题
const double _kBlockAreaTop = 64.0; // header + subtitle + 间距
const double _kBlockRowHeight = 34.0; // 每个 Block 行高
const double _kPinRadius = 6.0;

/// System 输入引脚在节点内的纵向中心（header 中心）
const double _kSystemInputPinY = 22.0;

/// 引脚触控半径（移动端需要比视觉更大的可点区域）
const double _kPinTapRadius = 14.0;

/// 节点卡片高度（用于画布尺寸与引脚计算）
double nodeCardHeight(SystemPayloadInstance sys) {
  return _kBlockAreaTop + sys.blocks.length * _kBlockRowHeight + 12.0;
}

/// Block 行在节点内的纵向中心
double _blockRowCenterY(int blockIndex) =>
    _kBlockAreaTop + blockIndex * _kBlockRowHeight + _kBlockRowHeight / 2;

/// 有向图编排器（类 UE Blueprint 节点连线）
///
/// - 画布支持双指缩放（0.5x ~ 2.5x）与单指平移；
/// - System 节点可拖动定位；
/// - 每个 Block 有输入（左）/ 输出（右）引脚，System 节点有输入引脚；
/// - 连线支持两种方式：
///   1. 点选（移动端友好）：点击起点 Block 输出引脚（自动高亮），
///      再点击目标 System / Block 的输入引脚完成连接；
///   2. 拖拽：从 Block 输出引脚拖到 System / Block 输入引脚；
///   （起点必须是 Block，终点可以是 System 或 Block）
/// - 底部为可收起的抽屉式 System 调色板，拖拽放入画布。
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

  final TransformationController _transformController =
      TransformationController();
  final GlobalKey _ivKey = GlobalKey();

  bool _drawerOpen = false;

  /// 正在拖线的起点 {nodeId, blockId}
  Map<String, String>? _dragFrom;

  /// 拖线指针在画布坐标系的位置
  Offset? _dragPointer;

  /// 拖线期间最后的全局指针位置（onPanEnd 无位置信息，需缓存）
  Offset? _lastGlobalPos;

  /// 点选连线的起点 {nodeId, blockId}（移动端友好交互）
  Map<String, String>? _wireSource;

  bool _isSource(String nodeId, String blockId) =>
      _wireSource != null &&
      _wireSource!['nodeId'] == nodeId &&
      _wireSource!['blockId'] == blockId;

  void _mutate(VoidCallback fn) {
    setState(fn);
    widget.onChanged();
  }

  double get _canvasWidth => math.max(
    900.0,
    draft.systems.fold<double>(
      0.0,
      (value, sys) => math.max(value, sys.x + _kNodeWidth + 120),
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
  // 坐标换算：全局坐标 → 画布（scene）坐标
  // -------------------------------------------------------------------------

  Offset _globalToScene(Offset global) {
    final ctx = _ivKey.currentContext;
    if (ctx == null) return global;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return global;
    final local = box.globalToLocal(global);
    return _transformController.toScene(local);
  }

  // -------------------------------------------------------------------------
  // 引脚位置（画布坐标系）
  // -------------------------------------------------------------------------

  Offset _systemInputPinPos(SystemPayloadInstance sys) =>
      Offset(sys.x, sys.y + _kSystemInputPinY);

  Offset _blockInputPinPos(SystemPayloadInstance sys, int blockIndex) =>
      Offset(sys.x, sys.y + _blockRowCenterY(blockIndex));

  // -------------------------------------------------------------------------
  // 编排操作
  // -------------------------------------------------------------------------

  void _selectRoot(String specId) => _mutate(() {
    draft.root.specId = specId;
    draft.root.params = {};
  });

  void _addSystemAt(String specId, Offset scenePos) {
    _mutate(() {
      draft.systems.add(
        SystemPayloadInstance(
          specId: specId,
          nodeId: 'node_${DateTime.now().microsecondsSinceEpoch}',
          x: math.max(0.0, scenePos.dx - _kNodeWidth / 2),
          y: math.max(0.0, scenePos.dy - _kHeaderHeight / 2),
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
    // 清理指向已删除节点的点选起点
    if (_wireSource?['nodeId'] == instance.nodeId) {
      setState(() => _wireSource = null);
    }
  }

  void _addBlock(SystemPayloadInstance instance, String blockId) {
    if (instance.blocks.any((b) => b.specId == blockId)) return;
    _mutate(() => instance.blocks.add(BlockPayloadInstance(specId: blockId)));
  }

  void _removeBlock(SystemPayloadInstance instance, int index) {
    final removed = instance.blocks[index];
    _mutate(() {
      instance.blocks.removeAt(index);
      // 删除 Block 时清理引用它的边
      draft.edges.removeWhere(
        (e) =>
            (e.fromNodeId == instance.nodeId &&
                e.fromBlockId == removed.instanceId) ||
            (e.toNodeId == instance.nodeId &&
                e.toBlockId == removed.instanceId),
      );
    });
    // 清理指向已删除 Block 的点选起点
    if (_wireSource != null &&
        _wireSource!['nodeId'] == instance.nodeId &&
        _wireSource!['blockId'] == removed.instanceId) {
      setState(() => _wireSource = null);
    }
  }

  // -------------------------------------------------------------------------
  // 引脚拖线
  // -------------------------------------------------------------------------

  void _startDragWire(String nodeId, String blockId) {
    setState(() {
      _dragFrom = {'nodeId': nodeId, 'blockId': blockId};
      _dragPointer = null;
    });
  }

  void _updateDragWire(Offset globalPos) {
    if (_dragFrom == null) return;
    _lastGlobalPos = globalPos;
    setState(() => _dragPointer = _globalToScene(globalPos));
  }

  void _endDragWire() {
    final from = _dragFrom;
    if (from == null) return;
    final scenePos = _lastGlobalPos != null
        ? _globalToScene(_lastGlobalPos!)
        : null;
    if (scenePos == null) {
      setState(() {
        _dragFrom = null;
        _dragPointer = null;
      });
      return;
    }

    // 寻找最近的输入引脚
    const hitRadius = 28.0;
    String? hitNodeId;
    String? hitBlockId; // null 表示命中 System 输入引脚
    double bestDist = hitRadius;

    for (final sys in draft.systems) {
      // System 输入引脚
      final sp = _systemInputPinPos(sys);
      final d = (sp - scenePos).distance;
      if (d < bestDist) {
        bestDist = d;
        hitNodeId = sys.nodeId;
        hitBlockId = null;
      }
      // Block 输入引脚
      for (var i = 0; i < sys.blocks.length; i++) {
        final bp = _blockInputPinPos(sys, i);
        final d2 = (bp - scenePos).distance;
        if (d2 < bestDist) {
          bestDist = d2;
          hitNodeId = sys.nodeId;
          hitBlockId = sys.blocks[i].instanceId;
        }
      }
    }

    setState(() {
      _dragFrom = null;
      _dragPointer = null;
    });

    if (hitNodeId == null) return;
    // 不能连接到自己所在的同一个 Block（自环）
    if (hitNodeId == from['nodeId'] && hitBlockId == from['blockId']) {
      _toast('不能连接到自身');
      return;
    }
    _connect(
      fromNodeId: from['nodeId']!,
      fromBlockId: from['blockId']!,
      toNodeId: hitNodeId,
      toBlockId: hitBlockId,
    );
  }

  // -------------------------------------------------------------------------
  // 点选连线（移动端友好：点起点 → 高亮 → 点终点）
  // -------------------------------------------------------------------------

  /// 点选/取消起点（Block 输出引脚）
  void _toggleWireSource(String nodeId, String blockId) {
    final wasSelected = _isSource(nodeId, blockId);
    setState(() {
      _wireSource = wasSelected ? null : {'nodeId': nodeId, 'blockId': blockId};
    });
    if (!wasSelected) {
      _toast(
        '已选中起点「${_nodeName(nodeId)} · ${_blockName(nodeId, blockId)}」，'
        '再点击目标端或模块的输入引脚完成连接',
      );
    }
  }

  /// 点选终点（[toBlockId] 为 null 表示 System 输入引脚）
  void _tapInputPin(String nodeId, String? blockId) {
    final from = _wireSource;
    if (from == null) {
      _toast('请先点击起点模块右侧的输出引脚');
      return;
    }
    if (nodeId == from['nodeId'] && blockId == from['blockId']) {
      _toast('不能连接到自身');
      return;
    }
    setState(() => _wireSource = null);
    _connect(
      fromNodeId: from['nodeId']!,
      fromBlockId: from['blockId']!,
      toNodeId: nodeId,
      toBlockId: blockId,
    );
  }

  /// 点击画布空白处取消点选起点
  void _cancelWireSource() {
    if (_wireSource == null) return;
    setState(() => _wireSource = null);
  }

  void _connect({
    required String fromNodeId,
    required String fromBlockId,
    required String toNodeId,
    String? toBlockId,
  }) {
    final exists = draft.edges.any(
      (e) =>
          e.fromNodeId == fromNodeId &&
          e.fromBlockId == fromBlockId &&
          e.toNodeId == toNodeId &&
          e.toBlockId == toBlockId,
    );
    if (exists) {
      _toast('这条连接已存在');
      return;
    }
    _mutate(() {
      draft.edges.add(
        DesignEdge(
          id: 'edge_${DateTime.now().microsecondsSinceEpoch}',
          fromNodeId: fromNodeId,
          fromBlockId: fromBlockId,
          toNodeId: toNodeId,
          toBlockId: toBlockId,
          kind: DesignEdgeKind.navigate,
        ),
      );
    });
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

  String _blockName(String nodeId, String? blockId) {
    if (blockId == null) return '';
    final block = draft.blockById(nodeId, blockId);
    if (block == null) return '已删除的模块';
    return BlockPayloadRegistry.byId(block.specId).name;
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
        _buildDrawer(isDark),
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
          Text(
            'Root',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
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
          const Text(
            '点击模块右侧引脚选中起点，再点击目标端 / 模块左侧引脚完成连接',
            style: TextStyle(fontSize: 11, color: Colors.orange),
          ),
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
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) =>
            details.data.startsWith('system:'),
        onAcceptWithDetails: (details) {
          final specId = details.data.substring('system:'.length);
          if (specId == '__custom__') {
            _createCustomSystem();
            return;
          }
          final scenePos = _globalToScene(details.offset);
          _addSystemAt(specId, scenePos);
        },
        builder: (context, candidate, _) {
          return InteractiveViewer(
            key: _ivKey,
            transformationController: _transformController,
            minScale: 0.5,
            maxScale: 2.5,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(200),
            // 点击画布空白处取消已选中的连线起点
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _cancelWireSource,
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
                          dragFrom: _dragFrom,
                          dragPointer: _dragPointer,
                        ),
                      ),
                    ),
                    if (draft.systems.isEmpty)
                      Positioned(
                        left: 24,
                        top: 24,
                        child: Text(
                          '画布是空的：从底部抽屉拖动「端」到这里，\n'
                          '再为端添加模块，点击模块右侧引脚即可开始连线。',
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
          );
        },
      ),
    );
  }

  Widget _buildNode(SystemPayloadInstance sys, bool isDark) {
    final spec = SystemPayloadRegistry.byId(sys.specId);
    final folder = sys.params['folder']?.trim().isNotEmpty == true
        ? sys.params['folder']!
        : spec.defaultFolder;
    final library = sys.params['library'] ?? spec.defaultLibrary;
    // 该节点包含已选中的连线起点时高亮边框
    final hasWireSource = _wireSource?['nodeId'] == sys.nodeId;

    return Positioned(
      left: sys.x,
      top: sys.y,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          // details.delta 是屏幕逻辑像素，sys.x/y 是场景坐标，
          // 需除以当前缩放比例才能跟手。
          final scale = _transformController.value.getMaxScaleOnAxis();
          final s = scale == 0 ? 1.0 : scale;
          setState(() {
            sys.x = math.max(0.0, sys.x + details.delta.dx / s);
            sys.y = math.max(0.0, sys.y + details.delta.dy / s);
          });
          widget.onChanged();
        },
        child: Container(
          width: _kNodeWidth,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D30) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasWireSource
                  ? Colors.orange
                  : isDark
                  ? const Color(0xFF3C3C3C)
                  : const Color(0xFFE0E4E8),
              width: hasWireSource ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  SizedBox(
                    height: _kHeaderHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
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
                              minWidth: 26,
                              minHeight: 26,
                            ),
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
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            tooltip: '移除该端',
                            icon: const Icon(Icons.close, size: 15),
                            onPressed: () => _removeSystem(sys),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Subtitle
                  SizedBox(
                    height: _kSubtitleHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
                      child: Text(
                        '$folder/ · $library',
                        style: TextStyle(
                          fontSize: 10,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Blocks
                  for (var i = 0; i < sys.blocks.length; i++)
                    _buildBlockRow(sys, i, isDark),
                  // Add block
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                    child: InkWell(
                      onTap: () => _pickBlock(sys),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.5),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 13, color: Colors.orange),
                            SizedBox(width: 2),
                            Text(
                              '模块',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // System 输入引脚（左侧，header 中心）
              Positioned(
                left: -_kPinTapRadius,
                top: _kSystemInputPinY - _kPinTapRadius,
                child: _inputPin(isDark, nodeId: sys.nodeId),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBlockRow(SystemPayloadInstance sys, int index, bool isDark) {
    final instance = sys.blocks[index];
    final spec = BlockPayloadRegistry.byId(instance.specId);
    return SizedBox(
      height: _kBlockRowHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: InputChip(
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
              backgroundColor: isDark
                  ? const Color(0xFF3A3A3D)
                  : const Color(0xFFFFF4E5),
            ),
          ),
          // Block 输入引脚（左）
          Positioned(
            left: -_kPinTapRadius,
            top: _kBlockRowHeight / 2 - _kPinTapRadius,
            child: _inputPin(
              isDark,
              nodeId: sys.nodeId,
              blockId: instance.instanceId,
            ),
          ),
          // Block 输出引脚（右）
          Positioned(
            left: _kNodeWidth - _kPinTapRadius,
            top: _kBlockRowHeight / 2 - _kPinTapRadius,
            child: _outputPin(sys, index),
          ),
        ],
      ),
    );
  }

  /// 输入引脚（终点）。点选模式下点击它完成连接；
  /// 已选中起点时放大发光提示「可以点击我」。
  Widget _inputPin(bool isDark, {String? nodeId, String? blockId}) {
    final awaitingTarget = _wireSource != null;
    final pinSize = _kPinRadius * 2 * (awaitingTarget ? 1.4 : 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: nodeId == null ? null : () => _tapInputPin(nodeId, blockId),
      child: SizedBox(
        width: _kPinTapRadius * 2,
        height: _kPinTapRadius * 2,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: pinSize,
            height: pinSize,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF6AB7FF) : Colors.blueAccent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
              boxShadow: awaitingTarget
                  ? [
                      BoxShadow(
                        color: Colors.blueAccent.withValues(alpha: 0.7),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 输出引脚（起点）。点击选中/取消起点，也支持原拖拽连线。
  Widget _outputPin(SystemPayloadInstance sys, int blockIndex) {
    final blockId = sys.blocks[blockIndex].instanceId;
    final selected = _isSource(sys.nodeId, blockId);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggleWireSource(sys.nodeId, blockId),
      onPanStart: (_) => _startDragWire(sys.nodeId, blockId),
      onPanUpdate: (d) => _updateDragWire(d.globalPosition),
      onPanEnd: (_) => _endDragWire(),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: _kPinTapRadius * 2,
          height: _kPinTapRadius * 2,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _kPinRadius * 2 * (selected ? 1.5 : 1.0),
              height: _kPinRadius * 2 * (selected ? 1.5 : 1.0),
              decoration: BoxDecoration(
                color: selected ? Colors.deepOrange : Colors.orange,
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: Colors.white, width: 2)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.orangeAccent,
                    blurRadius: selected ? 12 : 4,
                    spreadRadius: selected ? 2 : 0,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 底部抽屉式 System 调色板
  // -------------------------------------------------------------------------

  Widget _buildDrawer(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _drawerOpen = !_drawerOpen),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _drawerOpen
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '端（System Payload）',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '拖入画布添加',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_drawerOpen)
            SizedBox(
              height: 64,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: SystemPayloadRegistry.all.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index == SystemPayloadRegistry.all.length) {
                    return Draggable<String>(
                      data: 'system:__custom__',
                      feedback: Material(
                        elevation: 6,
                        borderRadius: BorderRadius.circular(10),
                        child: _paletteChip(
                          icon: Icons.add,
                          label: '自定义端',
                          color: Colors.blueAccent,
                          isDark: isDark,
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.35,
                        child: _paletteChip(
                          icon: Icons.add,
                          label: '自定义端',
                          color: Colors.blueAccent,
                          isDark: isDark,
                        ),
                      ),
                      child: _paletteChip(
                        icon: Icons.add,
                        label: '自定义端',
                        color: Colors.blueAccent,
                        isDark: isDark,
                        onTap: _createCustomSystem,
                      ),
                    );
                  }
                  final spec = SystemPayloadRegistry.all[index];
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
                    childWhenDragging: Opacity(
                      opacity: 0.35,
                      child: _paletteChip(
                        icon: spec.icon,
                        label: spec.name,
                        color: Colors.teal,
                        isDark: isDark,
                      ),
                    ),
                    child: Tooltip(
                      message: '拖入画布添加「${spec.name}」',
                      child: _paletteChip(
                        icon: spec.icon,
                        label: spec.name,
                        color: Colors.teal,
                        isDark: isDark,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
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
          color: isDark ? const Color(0xFF252527) : const Color(0xFFF8FAFC),
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
                        subtitle: Text(
                          block.description,
                          style: const TextStyle(fontSize: 11),
                        ),
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
                    '还没有关系。点击模块右侧引脚选中起点，再点击目标端 / 模块左侧引脚即可创建。',
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
                    child: Text(
                      '页面跳转与依赖关系',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
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
                        '${_nodeName(edge.fromNodeId)}.${_blockName(edge.fromNodeId, edge.fromBlockId)} → '
                        '${_nodeName(edge.toNodeId)}${edge.toBlockId == null ? '' : '.${_blockName(edge.toNodeId, edge.toBlockId)}'}',
                        style: const TextStyle(fontSize: 12),
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

/// 画布连线绘制（引脚到引脚 + live wire）
class _EdgePainter extends CustomPainter {
  final DesignDraft draft;
  final bool isDark;
  final Map<String, String>? dragFrom;
  final Offset? dragPointer;

  _EdgePainter({
    required this.draft,
    required this.isDark,
    this.dragFrom,
    this.dragPointer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 已有边
    for (final edge in draft.edges) {
      final from = draft.nodeById(edge.fromNodeId);
      final to = draft.nodeById(edge.toNodeId);
      if (from == null || to == null) continue;

      final fromBlockIdx = from.blocks.indexWhere(
        (b) => b.instanceId == edge.fromBlockId,
      );
      if (fromBlockIdx < 0) continue;
      final start = Offset(
        from.x + _kNodeWidth,
        from.y + _blockRowCenterY(fromBlockIdx),
      );

      final Offset end;
      if (edge.toBlockId == null) {
        end = Offset(to.x, to.y + _kSystemInputPinY);
      } else {
        final toBlockIdx = to.blocks.indexWhere(
          (b) => b.instanceId == edge.toBlockId,
        );
        if (toBlockIdx < 0) continue;
        end = Offset(to.x, to.y + _blockRowCenterY(toBlockIdx));
      }

      _drawEdge(canvas, start, end, edge.kind, edge.label, false);
    }

    // live wire
    if (dragFrom != null && dragPointer != null) {
      final from = draft.nodeById(dragFrom!['nodeId']);
      if (from != null) {
        final idx = from.blocks.indexWhere(
          (b) => b.instanceId == dragFrom!['blockId'],
        );
        if (idx >= 0) {
          final start = Offset(
            from.x + _kNodeWidth,
            from.y + _blockRowCenterY(idx),
          );
          _drawEdge(
            canvas,
            start,
            dragPointer!,
            DesignEdgeKind.navigate,
            null,
            true,
          );
        }
      }
    }
  }

  void _drawEdge(
    Canvas canvas,
    Offset start,
    Offset end,
    DesignEdgeKind kind,
    String? label,
    bool isLiveWire,
  ) {
    final color = kind == DesignEdgeKind.navigate
        ? Colors.blueAccent
        : Colors.orange;
    final paint = Paint()
      ..color = isLiveWire
          ? color.withValues(alpha: 0.85)
          : color.withValues(alpha: 0.8)
      ..strokeWidth = isLiveWire ? 2.0 : 1.6
      ..style = PaintingStyle.stroke;

    // 贝塞尔曲线（水平控制点，避免回头）
    final dx = end.dx - start.dx;
    final controlOffset = math.max(60.0, dx.abs() * 0.5);
    final c1 = Offset(start.dx + controlOffset, start.dy);
    final c2 = Offset(end.dx - controlOffset, end.dy);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);

    if (isLiveWire) return;

    // 箭头
    final tangent = (end - c2);
    final angle = math.atan2(tangent.dy, tangent.dx);
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
    if (label != null) {
      final text = label.isEmpty ? kind.label : label;
      final span = TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 9.5,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      );
      final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
        ..layout();
      // 曲线中点近似
      final mid = Offset(
        0.125 * start.dx + 0.375 * c1.dx + 0.375 * c2.dx + 0.125 * end.dx,
        0.125 * start.dy + 0.375 * c1.dy + 0.375 * c2.dy + 0.125 * end.dy,
      );
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: mid,
          width: tp.width + 10,
          height: tp.height + 6,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = isDark ? const Color(0xFF252527) : const Color(0xFFF8FAFC),
      );
      tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => true;
}
