import 'dart:convert';
import 'package:path/path.dart' as p;

/// 项目信息模型
class Project {
  final String name;
  final String path;
  final DateTime createdAt;

  /// 最近一次编辑时间（旧数据缺失时退回 [createdAt]）
  final DateTime? lastEditedAt;

  /// 关联的远程仓库（`owner/repo`，可为空）
  final String? repoFullName;

  /// 远程平台标识（github / gitee，可为空）
  final String? host;

  /// 本地路径不存在（仅内存态，不持久化）：跨设备同步回来的记录
  final bool missing;

  const Project({
    required this.name,
    required this.path,
    required this.createdAt,
    this.lastEditedAt,
    this.repoFullName,
    this.host,
    this.missing = false,
  });

  String get pubspecPath => p.join(path, 'pubspec.yaml');

  /// 最近活动时间（排序用）
  DateTime get activityAt => lastEditedAt ?? createdAt;

  Project copyWith({
    String? name,
    String? path,
    DateTime? createdAt,
    DateTime? lastEditedAt,
    String? repoFullName,
    String? host,
    bool? missing,
  }) {
    return Project(
      name: name ?? this.name,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
      repoFullName: repoFullName ?? this.repoFullName,
      host: host ?? this.host,
      missing: missing ?? this.missing,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'path': path,
      'createdAt': createdAt.toIso8601String(),
      if (lastEditedAt != null)
        'lastEditedAt': lastEditedAt!.toIso8601String(),
      if (repoFullName != null) 'repoFullName': repoFullName,
      if (host != null) 'host': host,
    };
  }

  factory Project.fromMap(Map<String, dynamic> map) {
    return Project(
      name: map['name'] as String,
      path: map['path'] as String,
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastEditedAt: DateTime.tryParse(map['lastEditedAt'] as String? ?? ''),
      repoFullName: map['repoFullName'] as String?,
      host: map['host'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory Project.fromJson(String source) =>
      Project.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
