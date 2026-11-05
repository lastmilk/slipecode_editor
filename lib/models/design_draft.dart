import 'dart:convert';

/// 设计稿（Design Draft）
///
/// 用户在可视化编辑器中拖拽编排 Root / System / Block 三层 Payload
/// 并填写每个 Payload 的参数后得到的完整组装结果。
/// 设计稿本身即包含完整的 Vibe：创建 Loader 项目时选择「采用设计稿」，
/// 引擎即可据此自动生成目录结构与全部 .md 文本。
///
/// 新版设计稿采用「有向图」编排：
/// - 节点（node）= 一个 System Payload 实例，节点上挂载 Block Payload；
/// - 边（edge）= 端之间的线性跳转（navigate）或依赖关系（depend）。
/// 这更贴合真实网站「页面跳转 + 模块依赖」的组织方式。
class DesignDraft {
  final String id;
  String name;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 根 Payload（项目初始环境）
  RootPayloadInstance root;

  /// 编排进来的 System Payload（有序）
  List<SystemPayloadInstance> systems;

  /// 节点之间的有向边
  List<DesignEdge> edges;

  DesignDraft({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.root,
    required this.systems,
    List<DesignEdge>? edges,
  }) : edges = edges ?? [];

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'root': root.toMap(),
        'systems': systems.map((s) => s.toMap()).toList(),
        'edges': edges.map((e) => e.toMap()).toList(),
      };

  factory DesignDraft.fromMap(Map<String, dynamic> map) {
    final rawSystems = ((map['systems'] as List?) ?? const []);
    final systems = rawSystems
        .map((e) =>
            SystemPayloadInstance.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
    // 旧数据迁移：没有 nodeId 的节点按顺序补一个；没有坐标的自动网格布局
    for (var i = 0; i < systems.length; i++) {
      if (systems[i].nodeId.isEmpty) {
        systems[i].nodeId = 'node_$i';
      }
      final raw = (rawSystems[i] as Map?)?.cast<String, dynamic>() ?? const {};
      if (raw['x'] == null || raw['y'] == null) {
        systems[i].x = 40.0 + (i % 3) * 280.0;
        systems[i].y = 40.0 + (i ~/ 3) * 220.0;
      }
    }
    var edges = ((map['edges'] as List?) ?? const [])
        .map((e) => DesignEdge.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
    // 旧设计稿没有边：按原有顺序生成一条线性跳转链，保持旧的阅读顺序语义
    if (edges.isEmpty && systems.length > 1) {
      for (var i = 0; i < systems.length - 1; i++) {
        edges.add(DesignEdge(
          id: 'edge_$i',
          fromNodeId: systems[i].nodeId,
          toNodeId: systems[i + 1].nodeId,
          label: '',
          kind: DesignEdgeKind.navigate,
        ));
      }
    }
    return DesignDraft(
      id: map['id'] as String,
      name: map['name'] as String? ?? '未命名设计稿',
      createdAt:
          DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updatedAt'] as String? ?? '') ?? DateTime.now(),
      root: RootPayloadInstance.fromMap(
          (map['root'] as Map).cast<String, dynamic>()),
      systems: systems,
      edges: edges,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory DesignDraft.fromJson(String source) =>
      DesignDraft.fromMap(jsonDecode(source) as Map<String, dynamic>);

  SystemPayloadInstance? nodeById(String? nodeId) {
    if (nodeId == null) return null;
    for (final s in systems) {
      if (s.nodeId == nodeId) return s;
    }
    return null;
  }
}

/// Root Payload 实例（specId + 参数值）
class RootPayloadInstance {
  String specId;
  Map<String, String> params;

  RootPayloadInstance({required this.specId, Map<String, String>? params})
      : params = params ?? {};

  Map<String, dynamic> toMap() => {'specId': specId, 'params': params};

  factory RootPayloadInstance.fromMap(Map<String, dynamic> map) =>
      RootPayloadInstance(
        specId: map['specId'] as String? ?? '',
        params: ((map['params'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', '$v')),
      );
}

/// System Payload 实例（specId + 参数值 + 其下编排的 Block 实例）
class SystemPayloadInstance {
  String specId;
  Map<String, String> params;
  List<BlockPayloadInstance> blocks;

  /// 图节点标识（同一设计稿内唯一）
  String nodeId;

  /// 节点在画布上的坐标（逻辑像素）
  double x;
  double y;

  SystemPayloadInstance({
    required this.specId,
    Map<String, String>? params,
    List<BlockPayloadInstance>? blocks,
    String? nodeId,
    this.x = 0.0,
    this.y = 0.0,
  })  : params = params ?? {},
        blocks = blocks ?? [],
        nodeId = nodeId ?? '';

  /// 所在目录（参数中的 folder，缺省用 specId）
  String get folder {
    final f = params['folder']?.trim() ?? '';
    return f.isEmpty ? specId : f;
  }

  Map<String, dynamic> toMap() => {
        'specId': specId,
        'nodeId': nodeId,
        'x': x,
        'y': y,
        'params': params,
        'blocks': blocks.map((b) => b.toMap()).toList(),
      };

  factory SystemPayloadInstance.fromMap(Map<String, dynamic> map) =>
      SystemPayloadInstance(
        specId: map['specId'] as String? ?? '',
        nodeId: map['nodeId'] as String? ?? '',
        x: (map['x'] as num?)?.toDouble() ?? 0.0,
        y: (map['y'] as num?)?.toDouble() ?? 0.0,
        params: ((map['params'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', '$v')),
        blocks: ((map['blocks'] as List?) ?? const [])
            .map((e) =>
                BlockPayloadInstance.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// Block Payload 实例（specId + 参数值）
class BlockPayloadInstance {
  String specId;
  Map<String, String> params;

  BlockPayloadInstance({required this.specId, Map<String, String>? params})
      : params = params ?? {};

  Map<String, dynamic> toMap() => {'specId': specId, 'params': params};

  factory BlockPayloadInstance.fromMap(Map<String, dynamic> map) =>
      BlockPayloadInstance(
        specId: map['specId'] as String? ?? '',
        params: ((map['params'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', '$v')),
      );
}

/// 有向边类型
enum DesignEdgeKind {
  /// 线性跳转：源端可以跳转到目标端（如门户 → 控制台）
  navigate,

  /// 依赖关系：目标端依赖源端（如控制台依赖开放平台的鉴权）
  depend,
}

extension DesignEdgeKindLabel on DesignEdgeKind {
  String get label => this == DesignEdgeKind.navigate ? '跳转' : '依赖';

  String get arrowHint =>
      this == DesignEdgeKind.navigate ? '可跳转到' : '依赖于';
}

/// 设计稿中的一条有向边
class DesignEdge {
  final String id;
  final String fromNodeId;
  final String toNodeId;

  /// 边上的说明文案（可为空，默认取 kind 的语义）
  String label;

  DesignEdgeKind kind;

  DesignEdge({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    this.label = '',
    this.kind = DesignEdgeKind.navigate,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'fromNodeId': fromNodeId,
        'toNodeId': toNodeId,
        'label': label,
        'kind': kind.name,
      };

  factory DesignEdge.fromMap(Map<String, dynamic> map) => DesignEdge(
        id: map['id'] as String? ?? '',
        fromNodeId: map['fromNodeId'] as String? ?? '',
        toNodeId: map['toNodeId'] as String? ?? '',
        label: map['label'] as String? ?? '',
        kind: DesignEdgeKind.values.firstWhere(
          (k) => k.name == map['kind'],
          orElse: () => DesignEdgeKind.navigate,
        ),
      );
}
