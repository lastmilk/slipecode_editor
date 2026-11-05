import 'dart:convert';

/// 设计稿（Design Draft）
///
/// 用户在可视化编辑器中拖拽编排 Root / System / Block 三层 Payload
/// 并填写每个 Payload 的参数后得到的完整组装结果。
/// 设计稿本身即包含完整的 Vibe：创建 Loader 项目时选择「采用设计稿」，
/// 引擎即可据此自动生成目录结构与全部 .md 文本。
class DesignDraft {
  final String id;
  String name;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 根 Payload（项目初始环境）
  RootPayloadInstance root;

  /// 编排进来的 System Payload（有序）
  List<SystemPayloadInstance> systems;

  DesignDraft({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.root,
    required this.systems,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'root': root.toMap(),
        'systems': systems.map((s) => s.toMap()).toList(),
      };

  factory DesignDraft.fromMap(Map<String, dynamic> map) => DesignDraft(
        id: map['id'] as String,
        name: map['name'] as String? ?? '未命名设计稿',
        createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(map['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        root: RootPayloadInstance.fromMap(
            (map['root'] as Map).cast<String, dynamic>()),
        systems: ((map['systems'] as List?) ?? const [])
            .map((e) =>
                SystemPayloadInstance.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  String toJson() => jsonEncode(toMap());

  factory DesignDraft.fromJson(String source) =>
      DesignDraft.fromMap(jsonDecode(source) as Map<String, dynamic>);
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

  SystemPayloadInstance({
    required this.specId,
    Map<String, String>? params,
    List<BlockPayloadInstance>? blocks,
  })  : params = params ?? {},
        blocks = blocks ?? [];

  /// 所在目录（参数中的 folder，缺省用 specId）
  String get folder {
    final f = params['folder']?.trim() ?? '';
    return f.isEmpty ? specId : f;
  }

  Map<String, dynamic> toMap() => {
        'specId': specId,
        'params': params,
        'blocks': blocks.map((b) => b.toMap()).toList(),
      };

  factory SystemPayloadInstance.fromMap(Map<String, dynamic> map) =>
      SystemPayloadInstance(
        specId: map['specId'] as String? ?? '',
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
