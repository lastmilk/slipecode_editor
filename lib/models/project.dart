import 'dart:convert';
import 'package:path/path.dart' as p;

/// 项目信息模型
class Project {
  final String name;
  final String path;
  final DateTime createdAt;

  const Project({
    required this.name,
    required this.path,
    required this.createdAt,
  });

  String get pubspecPath => p.join(path, 'pubspec.yaml');

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'path': path,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Project.fromMap(Map<String, dynamic> map) {
    return Project(
      name: map['name'] as String,
      path: map['path'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory Project.fromJson(String source) =>
      Project.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
