import 'package:flutter/material.dart';

/// 场景符号类型。
///
/// 每个场景对应一种动态背景符号，供大厅卡片与流程页绘制。
enum SceneSymbolKind { coding, video, auto, text, chat }

/// 场景的二级选项：项目细分元素（产出形态）。
class SceneElement {
  final String id;

  /// 展示名，如「移动应用」。
  final String name;

  /// 一句中文描述。
  final String description;

  /// 卡片图标。
  final IconData icon;

  const SceneElement({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
  });
}

/// 场景的三级选项：项目类型（范式 / 技术栈 / 模板）。
class SceneProjectType {
  final String id;

  /// 展示名，如「新范式」。
  final String name;

  /// 一句中文描述。
  final String description;

  /// 角标文案，如「推荐」。
  final String? badge;

  /// 落点路由：VibeCoding 使用 `loader` / `classic`，其余场景为 null。
  final String? route;

  const SceneProjectType({
    required this.id,
    required this.name,
    required this.description,
    this.badge,
    this.route,
  });
}

/// 场景定义。
class SceneDefinition {
  final String id;

  /// 英文主标题，如 `VibeCoding`。
  final String name;

  /// 中文价值描述。
  final String tagline;

  /// 场景强调色。
  final Color accent;

  /// 动态背景符号类型。
  final SceneSymbolKind symbol;

  /// 是否为大厅主卡（VibeCoding 为 true）。
  final bool isPrimary;

  /// 二级选项（细分元素）。
  final List<SceneElement> elements;

  /// 默认的三级选项（细分元素未单独配置时使用）。
  final List<SceneProjectType> types;

  /// 按细分元素区分的三级选项。
  final Map<String, List<SceneProjectType>> typesByElement;

  const SceneDefinition({
    required this.id,
    required this.name,
    required this.tagline,
    required this.accent,
    required this.symbol,
    this.isPrimary = false,
    required this.elements,
    required this.types,
    this.typesByElement = const {},
  });

  /// 按 id 查找细分元素。
  SceneElement? elementById(String id) {
    for (final element in elements) {
      if (element.id == id) return element;
    }
    return null;
  }

  /// 按 id 查找项目类型（含 `typesByElement` 中的类型）。
  SceneProjectType? typeById(String id) {
    for (final type in types) {
      if (type.id == id) return type;
    }
    for (final list in typesByElement.values) {
      for (final type in list) {
        if (type.id == id) return type;
      }
    }
    return null;
  }

  /// 获取某个细分元素下可用的项目类型。
  ///
  /// 优先读取 [typesByElement]，未配置时退回 [types]。
  List<SceneProjectType> typesForElement(String elementId) {
    final configured = typesByElement[elementId];
    if (configured != null && configured.isNotEmpty) return configured;
    return types;
  }
}

/// 用户的三级选择结果。
class SceneSelection {
  final String sceneId;
  final String? elementId;
  final String? typeId;

  const SceneSelection({
    required this.sceneId,
    this.elementId,
    this.typeId,
  });

  /// 场景、细分元素、项目类型均已选择。
  bool get isComplete =>
      sceneId.isNotEmpty &&
      (elementId?.isNotEmpty ?? false) &&
      (typeId?.isNotEmpty ?? false);

  SceneSelection copyWith({
    String? sceneId,
    String? elementId,
    String? typeId,
  }) {
    return SceneSelection(
      sceneId: sceneId ?? this.sceneId,
      elementId: elementId ?? this.elementId,
      typeId: typeId ?? this.typeId,
    );
  }

  Map<String, dynamic> toJson() => {
        'sceneId': sceneId,
        if (elementId != null) 'elementId': elementId,
        if (typeId != null) 'typeId': typeId,
      };

  factory SceneSelection.fromJson(Map<String, dynamic> json) {
    return SceneSelection(
      sceneId: json['sceneId'] as String? ?? '',
      elementId: json['elementId'] as String?,
      typeId: json['typeId'] as String?,
    );
  }
}
