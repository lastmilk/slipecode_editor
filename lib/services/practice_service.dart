import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../community/practice_catalog.dart';

/// 自动检查结果
class PracticeCheckResult {
  final bool passed;
  final List<String> issues;
  final List<String> passedChecks;

  const PracticeCheckResult({
    required this.passed,
    this.issues = const [],
    this.passedChecks = const [],
  });

  double get progress {
    final total = issues.length + passedChecks.length;
    if (total == 0) return 0;
    return passedChecks.length / total;
  }
}

/// 教学模式：创建临时练习项目并做规则化检查
class PracticeService {
  PracticeService._();

  static final PracticeService instance = PracticeService._();

  static const String entryFile = 'lib/main.dart';

  /// 创建（或重置）临时练习项目，返回项目根目录
  Future<String> createProject(PracticeSpec spec) async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'slipe_practice', spec.lessonId));
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await Directory(p.join(root.path, 'lib')).create(recursive: true);

    final packageName =
        'practice_${spec.lessonId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
    await File(p.join(root.path, 'pubspec.yaml')).writeAsString(
      "name: $packageName\n"
      "description: SLIPE 教学模式临时练习项目\n"
      "publish_to: 'none'\n"
      "version: 1.0.0+1\n"
      "environment:\n"
      "  sdk: '>=3.0.0 <4.0.0'\n"
      "dependencies:\n"
      "  flutter:\n"
      "    sdk: flutter\n",
      flush: true,
    );
    await File(p.join(root.path, 'README.md')).writeAsString(
      '# ${spec.title}\n\n## 需求\n\n${spec.requirement}\n\n'
      '完成后回到教学模式悬浮球，点击「提交检查」。\n',
      flush: true,
    );
    await File(p.join(root.path, entryFile))
        .writeAsString(spec.starter, flush: true);
    return root.path;
  }

  /// 检查用户代码
  Future<PracticeCheckResult> check(
    String projectPath,
    PracticeSpec spec,
  ) async {
    final file = File(p.join(projectPath, entryFile));
    if (!await file.exists()) {
      return const PracticeCheckResult(
        passed: false,
        issues: ['找不到 lib/main.dart，请先补全代码'],
      );
    }
    final content = await file.readAsString();
    final issues = <String>[];
    final passed = <String>[];

    if (content.trim().isEmpty) {
      return const PracticeCheckResult(
        passed: false,
        issues: ['lib/main.dart 还是空的'],
      );
    }
    if (content.contains('TODO')) {
      issues.add('还有 TODO 注释未完成');
    } else {
      passed.add('已完成全部 TODO');
    }

    if (_balanced(content)) {
      passed.add('括号配对正常');
    } else {
      issues.add('括号不匹配，请检查 (), {} 与 []');
    }

    for (final token in spec.requiredTokens) {
      if (content.contains(token)) {
        passed.add('包含 $token');
      } else {
        issues.add('缺少关键结构：$token');
      }
    }
    for (final token in spec.forbiddenTokens) {
      if (content.contains(token)) {
        issues.add('不建议使用：$token');
      }
    }
    if (spec.strict && !content.contains('const ')) {
      issues.add('最佳实践题目需要适当使用 const');
    }

    return PracticeCheckResult(
      passed: issues.isEmpty,
      issues: issues,
      passedChecks: passed,
    );
  }

  /// 检查代码中的括号是否配对（跳过字符串与注释）
  bool _balanced(String code) {
    final stack = <String>[];
    var i = 0;
    String? quote;
    while (i < code.length) {
      final ch = code[i];
      if (quote != null) {
        if (ch == '\\' && i + 1 < code.length) {
          i += 2;
          continue;
        }
        if (ch == quote) quote = null;
        i++;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < code.length && code[i + 1] == '/') {
        while (i < code.length && code[i] != '\n') {
          i++;
        }
        continue;
      }
      if (ch == '/' && i + 1 < code.length && code[i + 1] == '*') {
        i += 2;
        while (i + 1 < code.length &&
            !(code[i] == '*' && code[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
      if (ch == '(' || ch == '{' || ch == '[') {
        stack.add(ch);
      } else if (ch == ')' || ch == '}' || ch == ']') {
        if (stack.isEmpty) return false;
        final open = stack.removeLast();
        final ok = (open == '(' && ch == ')') ||
            (open == '{' && ch == '}') ||
            (open == '[' && ch == ']');
        if (!ok) return false;
      }
      i++;
    }
    return stack.isEmpty && quote == null;
  }
}
