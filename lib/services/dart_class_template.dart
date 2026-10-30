/// Dart 类模板种类
enum DartClassKind {
  plain('普通类', 'class'),
  statelessWidget('StatelessWidget', 'widget'),
  statefulWidget('StatefulWidget', 'widget'),
  service('服务类（单例）', 'service'),
  model('数据模型', 'model');

  final String label;
  final String group;

  const DartClassKind(this.label, this.group);
}

/// Dart 类模板生成器
class DartClassTemplate {
  DartClassTemplate._();

  /// 生成模板代码
  static String generate(DartClassKind kind, String className) {
    final name = pascalCase(className);
    switch (kind) {
      case DartClassKind.statelessWidget:
        return '''import 'package:flutter/material.dart';

class $name extends StatelessWidget {
  const $name({super.key});

  @override
  Widget build(BuildContext context) {
    return const Placeholder();
  }
}
''';
      case DartClassKind.statefulWidget:
        return '''import 'package:flutter/material.dart';

class $name extends StatefulWidget {
  const $name({super.key});

  @override
  State<$name> createState() => _${name}State();
}

class _${name}State extends State<$name> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return const Placeholder();
  }
}
''';
      case DartClassKind.service:
        return '''class $name {
  $name._();

  static final $name instance = $name._();
}
''';
      case DartClassKind.model:
        return '''class $name {
  final String id;

  const $name({required this.id});

  $name copyWith({String? id}) {
    return $name(id: id ?? this.id);
  }

  factory $name.fromJson(Map<String, dynamic> json) {
    return $name(id: json['id'] as String? ?? '');
  }

  Map<String, dynamic> toJson() => {'id': id};
}
''';
      case DartClassKind.plain:
        return '''class $name {
  const $name();
}
''';
    }
  }

  /// 类名 → 文件名（PascalCase / camelCase → snake_case）
  static String fileNameFor(String className) {
    final buffer = StringBuffer();
    final input = className.trim();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '_' || ch == ' ' || ch == '-') {
        if (buffer.isNotEmpty && !buffer.toString().endsWith('_')) {
          buffer.write('_');
        }
        continue;
      }
      final upper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
      if (upper && i > 0 && !buffer.toString().endsWith('_')) {
        buffer.write('_');
      }
      buffer.write(ch.toLowerCase());
    }
    return '${buffer.toString().replaceAll(RegExp(r'_+'), '_')}.dart';
  }

  /// 任意写法 → PascalCase
  static String pascalCase(String input) {
    final parts = input
        .trim()
        .split(RegExp(r'[_\-\s]+'))
        .where((part) => part.isNotEmpty);
    final buffer = StringBuffer();
    for (final part in parts) {
      buffer.write(part[0].toUpperCase());
      buffer.write(part.substring(1));
    }
    return buffer.toString();
  }
}
