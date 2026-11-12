import 'dart:convert';
import 'dart:math' as math;

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../services/design_draft_service.dart';
import 'mcp_tools.dart';

/// 设计稿专用 MCP 工具集（独立于代码编辑器 Agent）
///
/// AI 通过这些工具直接编排设计稿：选择 Root、添加端、挂载模块、
/// 修改参数、建立跳转/依赖关系，并在每次修改后自动保存。
class DesignToolkit {
  DesignToolkit({required this.draft, required this.onChanged});

  final DesignDraft draft;
  final void Function() onChanged;

  Future<void> _save() async {
    draft.updatedAt = DateTime.now();
    await DesignDraftService.instance.save(draft);
    onChanged();
  }

  String _state() {
    final systems = draft.systems.map((s) {
      final spec = SystemPayloadRegistry.byId(s.specId);
      final blocks = s.blocks
          .map((b) => '${BlockPayloadRegistry.byId(b.specId).name}(${b.specId})')
          .join('、');
      return '- node=${s.nodeId} 端=${spec.name}(${s.specId}) '
          '坐标=(${s.x.toStringAsFixed(0)},${s.y.toStringAsFixed(0)}) '
          '模块=${blocks.isEmpty ? '无' : blocks}';
    }).join('\n');
    final edges = draft.edges
        .map((e) =>
            '- ${e.fromNodeId}.${e.fromBlockId} → ${e.toNodeId}${e.toBlockId == null ? '' : '.${e.toBlockId}'} (${e.kind.label})')
        .join('\n');
    return '设计稿：${draft.name}（id=${draft.id}）\n'
        'Root=${RootPayloadRegistry.byId(draft.root.specId).name}'
        '（${draft.root.specId}）\n'
        '端（${draft.systems.length}）：\n${systems.isEmpty ? '无' : systems}\n'
        '关系（${draft.edges.length}）：\n${edges.isEmpty ? '无' : edges}';
  }

  List<McpTool> get tools => [
        McpTool(
          name: 'design_state',
          description: '获取当前设计稿的 Root、端、模块与关系列表。',
          parameters: _obj({}),
          execute: (_) async => _state(),
        ),
        McpTool(
          name: 'design_list_payloads',
          description: '列出可用的 Root / System / Block Payload 规格（含 id 与适用端）。',
          parameters: _obj({}),
          execute: (_) async {
            final roots = RootPayloadRegistry.all
                .map((r) =>
                    '- root:${r.id} ${r.name}（环境变量 ${r.envVars.length} 个）')
                .join('\n');
            final systems = SystemPayloadRegistry.all
                .map((s) => '- system:${s.id} ${s.name} · ${s.description}')
                .join('\n');
            final blocks = BlockPayloadRegistry.all
                .map((b) =>
                    '- block:${b.id} ${b.name}（适用：${b.applicableSystems.isEmpty ? '全部' : b.applicableSystems.join(',')}）')
                .join('\n');
            return 'Root（${RootPayloadRegistry.all.length}）：\n${roots.isEmpty ? '无（请先在社区导入）' : roots}\n\n'
                'System（${SystemPayloadRegistry.all.length}）：\n$systems\n\n'
                'Block（${BlockPayloadRegistry.all.length}）：\n$blocks';
          },
        ),
        McpTool(
          name: 'design_set_root',
          description: '设置设计稿的 Root Payload（构建镜像）。',
          parameters: _obj(
            {'spec_id': _str('RootPayload id，空字符串表示未选择')},
            required: ['spec_id'],
          ),
          execute: (args) async {
            final id = (args['spec_id'] ?? '').toString().trim();
            if (id.isNotEmpty && RootPayloadRegistry.all.every((r) => r.id != id)) {
              return '错误：RootPayload 不存在 $id';
            }
            draft.root.specId = id;
            draft.root.params = {};
            await _save();
            return '已设置 Root 为 ${RootPayloadRegistry.byId(id).name}';
          },
        ),
        McpTool(
          name: 'design_add_system',
          description: '在画布上新增一个端（System Payload），返回 node_id。',
          parameters: _obj(
            {
              'spec_id': _str('SystemPayload id'),
              'x': _num('画布 x 坐标（可选）'),
              'y': _num('画布 y 坐标（可选）'),
            },
            required: ['spec_id'],
          ),
          execute: (args) async {
            final specId = (args['spec_id'] ?? '').toString().trim();
            if (SystemPayloadRegistry.all.every((s) => s.id != specId)) {
              return '错误：SystemPayload 不存在 $specId';
            }
            final index = draft.systems.length;
            final node = SystemPayloadInstance(
              specId: specId,
              nodeId: 'node_${DateTime.now().microsecondsSinceEpoch}',
              x: (args['x'] as num?)?.toDouble() ??
                  (40.0 + (index % 3) * 280.0),
              y: (args['y'] as num?)?.toDouble() ??
                  (40.0 + (index ~/ 3) * 220.0),
            );
            draft.systems.add(node);
            await _save();
            return '已添加端 ${SystemPayloadRegistry.byId(specId).name}，node_id=${node.nodeId}';
          },
        ),
        McpTool(
          name: 'design_add_block',
          description: '给某个端挂载一个功能模块（Block Payload）。',
          parameters: _obj(
            {
              'node_id': _str('目标端的 node_id'),
              'block_id': _str('BlockPayload id'),
            },
            required: ['node_id', 'block_id'],
          ),
          execute: (args) async {
            final node = draft.nodeById((args['node_id'] ?? '').toString());
            if (node == null) return '错误：端不存在';
            final blockId = (args['block_id'] ?? '').toString().trim();
            final spec = BlockPayloadRegistry.byId(blockId);
            if (spec.id != blockId) return '错误：BlockPayload 不存在 $blockId';
            if (!spec.appliesTo(node.specId)) {
              return '错误：模块 ${spec.name} 不适用于该端';
            }
            if (node.blocks.any((b) => b.specId == blockId)) {
              return '错误：该端已包含模块 ${spec.name}';
            }
            node.blocks.add(BlockPayloadInstance(specId: blockId));
            await _save();
            return '已为端添加模块 ${spec.name}';
          },
        ),
        McpTool(
          name: 'design_set_params',
          description: '设置 Root / 端 / 模块的参数（params 为键值对对象）。',
          parameters: _obj(
            {
              'node_id': _str('端的 node_id（Root 参数可留空）'),
              'block_id': _str('模块 instanceId（可留空）'),
              'params': {
                'type': 'object',
                'description': '参数键值对',
                'additionalProperties': {'type': 'string'},
              },
            },
            required: ['params'],
          ),
          execute: (args) async {
            final raw = args['params'];
            if (raw is! Map) return '错误：params 必须是对象';
            final params = <String, String>{
              for (final e in raw.entries) '${e.key}': '${e.value}',
            };
            final nodeId = (args['node_id'] ?? '').toString();
            final blockId = (args['block_id'] ?? '').toString();
            if (nodeId.isEmpty) {
              draft.root.params.addAll(params);
              await _save();
              return '已更新 Root 参数';
            }
            final node = draft.nodeById(nodeId);
            if (node == null) return '错误：端不存在';
            if (blockId.isEmpty) {
              node.params.addAll(params);
            } else {
              final block =
                  node.blocks.where((b) => b.instanceId == blockId).firstOrNull;
              if (block == null) return '错误：模块不存在';
              block.params.addAll(params);
            }
            await _save();
            return '参数已更新';
          },
        ),
        McpTool(
          name: 'design_connect',
          description: '在两个端/模块之间建立跳转或依赖关系。',
          parameters: _obj(
            {
              'from_node_id': _str('起点端 node_id'),
              'from_block_id': _str('起点模块 instanceId'),
              'to_node_id': _str('终点端 node_id'),
              'to_block_id': _str('终点模块 instanceId（可空，表示整个端）'),
              'kind': _str('navigate 跳转 / depend 依赖，默认 navigate'),
            },
            required: ['from_node_id', 'from_block_id', 'to_node_id'],
          ),
          execute: (args) async {
            final fromNode = (args['from_node_id'] ?? '').toString();
            final fromBlock = (args['from_block_id'] ?? '').toString();
            final toNode = (args['to_node_id'] ?? '').toString();
            final toBlock = (args['to_block_id'] ?? '').toString();
            final src = draft.nodeById(fromNode);
            if (src == null) return '错误：起点端不存在';
            final block = src.blocks
                .where((b) => b.instanceId == fromBlock)
                .firstOrNull;
            if (block == null) return '错误：起点模块不存在';
            if (draft.nodeById(toNode) == null) return '错误：终点端不存在';
            final exists = draft.edges.any((e) =>
                e.fromNodeId == fromNode &&
                e.fromBlockId == fromBlock &&
                e.toNodeId == toNode &&
                e.toBlockId == (toBlock.isEmpty ? null : toBlock));
            if (exists) return '错误：该连接已存在';
            draft.edges.add(DesignEdge(
              id: 'edge_${DateTime.now().microsecondsSinceEpoch}',
              fromNodeId: fromNode,
              fromBlockId: fromBlock,
              toNodeId: toNode,
              toBlockId: toBlock.isEmpty ? null : toBlock,
              kind: (args['kind'] ?? '') == 'depend'
                  ? DesignEdgeKind.depend
                  : DesignEdgeKind.navigate,
            ));
            await _save();
            return '关系已创建';
          },
        ),
        McpTool(
          name: 'design_rename',
          description: '重命名当前设计稿。',
          parameters: _obj(
            {'name': _str('新的设计稿名称')},
            required: ['name'],
          ),
          execute: (args) async {
            final name = (args['name'] ?? '').toString().trim();
            if (name.isEmpty) return '错误：名称不能为空';
            draft.name = name;
            await _save();
            return '设计稿已重命名为 $name';
          },
        ),
        McpTool(
          name: 'design_remove_system',
          description: '移除一个端及其相关关系。',
          parameters: _obj(
            {'node_id': _str('要移除的端 node_id')},
            required: ['node_id'],
          ),
          execute: (args) async {
            final nodeId = (args['node_id'] ?? '').toString();
            final node = draft.nodeById(nodeId);
            if (node == null) return '错误：端不存在';
            draft.systems.remove(node);
            draft.edges.removeWhere(
              (e) => e.fromNodeId == nodeId || e.toNodeId == nodeId,
            );
            await _save();
            return '已移除端';
          },
        ),
      ];

  Map<String, dynamic> _obj(
    Map<String, dynamic> properties, {
    List<String>? required,
  }) =>
      {
        'type': 'object',
        'properties': properties,
        if (required != null && required.isNotEmpty) 'required': required,
      };

  Map<String, dynamic> _str(String description) =>
      {'type': 'string', 'description': description};

  Map<String, dynamic> _num(String description) =>
      {'type': 'number', 'description': description};

  /// 给 AI 的设计稿摘要（作为系统提示的一部分）
  String get summary => _state();

  /// 解析 JSON 参数（与主 Agent 一致）
  static Map<String, dynamic> decodeArgs(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) return Map<String, dynamic>.from(raw);
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }

  /// 自动布局辅助：为新端找一个空位
  double nextX() {
    final count = draft.systems.length;
    return 40.0 + (count % 3) * 280.0;
  }

  double nextY() {
    final count = draft.systems.length;
    return 40.0 + (count ~/ 3) * 220.0;
  }

  double maxCanvasWidth() => math.max(900.0, nextX() + 360);
}
