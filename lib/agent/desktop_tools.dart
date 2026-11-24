import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../services/ai_change_journal.dart';
import '../services/desktop_platform.dart';
import '../services/local_build/artifact_resolver.dart';
import '../services/local_build/local_build_models.dart';
import '../services/local_build/local_build_service.dart';
import '../services/lsp/lsp_manager.dart';
import '../services/lsp/lsp_session.dart';
import '../services/lsp/lsp_types.dart';
import '../services/tool_policy.dart';
import '../services/toolchain/toolchain_manager.dart';
import '../services/toolchain/toolchain_models.dart';
import 'mcp_tools.dart';

/// 桌面专属工具集：git / 搜索 / 质量 / LSP / 本地构建。
///
/// 桌面环境才有完整命令行，因此这里的工具在移动端不注册。
/// 所有命令都经过 [ToolPolicy] 校验与输出截断，写操作登记 [AiChangeJournal]。
List<McpTool> buildDesktopTools(McpToolbox box) {
  if (!DesktopPlatform.isDesktop) return const [];
  return [
    ..._gitTools(box),
    ..._searchTools(box),
    ..._qualityTools(box),
    ..._lspTools(box),
    ..._miscTools(box),
  ];
}

// -----------------------------------------------------------------------------
// git
// -----------------------------------------------------------------------------

List<McpTool> _gitTools(McpToolbox box) => [
  McpTool(
    name: 'git_status',
    description: '查看当前项目的 git 状态（分支 + 变更列表）。',
    parameters: _object({}),
    execute: (_) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      return _run(root, 'git', const ['status', '--short', '--branch']);
    },
  ),
  McpTool(
    name: 'git_diff',
    description: '查看工作区或暂存区的代码差异。',
    parameters: _object({
      'path': _string('限定文件或目录（相对项目根），省略表示全部'),
      'staged': _boolean('是否查看已暂存的差异，默认 false'),
    }),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final cliArgs = <String>['diff'];
      if (args['staged'] == true) cliArgs.add('--staged');
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      if ((args['path'] as String?)?.trim().isNotEmpty ?? false) {
        cliArgs.addAll(['--', target]);
      }
      return _run(root, 'git', cliArgs, timeout: const Duration(seconds: 60));
    },
  ),
  McpTool(
    name: 'git_log',
    description: '查看最近的提交记录。',
    parameters: _object({
      'limit': _integer('最大条数，默认 20'),
      'path': _string('限定文件或目录（相对项目根）'),
    }),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final limit = (args['limit'] as num?)?.toInt() ?? 20;
      final cliArgs = <String>[
        'log',
        '--oneline',
        '-n',
        '${limit.clamp(1, 200)}',
      ];
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      if ((args['path'] as String?)?.trim().isNotEmpty ?? false) {
        cliArgs.addAll(['--', target]);
      }
      return _run(root, 'git', cliArgs);
    },
  ),
  McpTool(
    name: 'git_commit',
    description: '提交指定文件。只暂存 files 里显式列出的文件，不会提交其他改动。',
    parameters: _object(
      {'message': _string('提交信息'), 'files': _array('要提交的文件路径列表（相对项目根）')},
      required: ['message', 'files'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final message = (args['message'] as String? ?? '').trim();
      if (message.isEmpty) return '错误：message 不能为空';
      final raw = (args['files'] as List? ?? const [])
          .map((item) => '$item')
          .where((item) => item.trim().isNotEmpty)
          .toList();
      if (raw.isEmpty) return '错误：请显式指定要提交的文件列表（files）';
      final paths = <String>[];
      for (final item in raw) {
        final resolved = _resolve(box, item);
        if (resolved == null) return '错误：路径超出项目范围 $item';
        paths.add(resolved);
      }
      final add = await _run(root, 'git', ['add', '--', ...paths]);
      if (add.startsWith('错误')) return add;
      return _run(root, 'git', [
        'commit',
        '-m',
        message,
      ], timeout: const Duration(seconds: 120));
    },
  ),
  McpTool(
    name: 'git_create_branch',
    description: '创建分支，默认同时切换到新分支。',
    parameters: _object(
      {'name': _string('分支名'), 'checkout': _boolean('创建后是否切换，默认 true')},
      required: ['name'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final name = (args['name'] as String? ?? '').trim();
      if (name.isEmpty) return '错误：name 不能为空';
      final checkout = args['checkout'] != false;
      final cliArgs = checkout ? ['checkout', '-b', name] : ['branch', name];
      return _run(root, 'git', cliArgs);
    },
  ),
  McpTool(
    name: 'git_checkout',
    description: '切换到已有分支 / 提交。禁止批量丢弃工作区改动。',
    parameters: _object({'target': _string('分支名、标签或提交')}, required: ['target']),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = (args['target'] as String? ?? '').trim();
      if (target.isEmpty) return '错误：target 不能为空';
      return _run(root, 'git', ['checkout', target]);
    },
  ),
  McpTool(
    name: 'git_stash',
    description: '暂存改动：action 可选 push / pop / apply / list。',
    parameters: _object({
      'action': _string('push / pop / apply / list，默认 push'),
      'message': _string('push 时的说明'),
    }),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final action = (args['action'] as String? ?? 'push').trim();
      final message = (args['message'] as String? ?? '').trim();
      final cliArgs = switch (action) {
        'list' => <String>['stash', 'list'],
        'pop' => <String>['stash', 'pop'],
        'apply' => <String>['stash', 'apply'],
        'push' => <String>[
          'stash',
          'push',
          if (message.isNotEmpty) ...['-m', message],
        ],
        _ => const <String>[],
      };
      if (cliArgs.isEmpty) return '错误：action 只能是 push / pop / apply / list';
      return _run(root, 'git', cliArgs);
    },
  ),
  McpTool(
    name: 'apply_patch',
    description:
        '应用统一 diff 补丁：先用 git apply --check 干跑校验，再写入文件；'
        '改动登记到 AI 改动台账，可撤回。',
    parameters: _object(
      {
        'patch': _string('统一 diff 文本（含 ---/+++ 文件头）'),
        'dry_run': _boolean('仅校验不写入，默认 false'),
      },
      required: ['patch'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final patch = args['patch'] as String? ?? '';
      if (patch.trim().isEmpty) return '错误：patch 不能为空';
      final paths = _patchPaths(patch)
          .map((path) => _resolve(box, path))
          .whereType<String>()
          .toList();
      if (paths.isEmpty) return '错误：未能从补丁中解析出文件路径';
      // 写盘前记录原始内容，用于撤回
      final before = <String, String?>{};
      for (final path in paths) {
        before[path] = await _fileText(path);
      }
      final temp = File(
        p.join(
          Directory.systemTemp.path,
          'slipe-patch-${DateTime.now().microsecondsSinceEpoch}.diff',
        ),
      );
      await temp.writeAsString(patch);
      try {
        final check = await _run(root, 'git', ['apply', '--check', temp.path]);
        if (check.startsWith('错误')) return check;
        if (args['dry_run'] == true) return '补丁校验通过（未写入文件）';
        final applied = await _run(root, 'git', ['apply', temp.path]);
        if (applied.startsWith('错误')) return applied;
      } finally {
        try {
          await temp.delete();
        } catch (_) {
          // 忽略临时文件清理失败
        }
      }
      final changed = <String>[];
      for (final path in paths) {
        final after = await _fileText(path);
        if (after == before[path]) continue;
        box.editor.replaceContent(path, after ?? '');
        AiChangeJournal.instance.record(
          kind: AiChangeKind.write,
          action: t('approval.write'),
          path: path,
          before: before[path],
          after: after,
        );
        changed.add(path);
      }
      if (changed.isEmpty) return '补丁已应用，但文件内容无变化';
      return '已应用补丁，修改文件：\n'
          '${changed.map((path) => '- ${_relative(root, path)}').join('\n')}';
    },
  ),
];

// -----------------------------------------------------------------------------
// 搜索
// -----------------------------------------------------------------------------

List<McpTool> _searchTools(McpToolbox box) => [
  McpTool(
    name: 'find_files',
    description: '按文件名 glob 查找项目内的文件（优先 ripgrep，遵循 .gitignore）。',
    parameters: _object({
      'pattern': _string('glob 模式，如 *.dart 或 lib/**/*.dart，默认 *'),
      'dir': _string('限定目录（相对项目根）'),
      'limit': _integer('最多返回条数，默认 200'),
    }),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final pattern = (args['pattern'] as String? ?? '*').trim();
      final dir = _resolve(box, args['dir'] as String?);
      if (dir == null) return '错误：路径超出项目范围';
      final limit = ((args['limit'] as num?)?.toInt() ?? 200).clamp(1, 1000);
      return _findFiles(root, dir: dir, pattern: pattern, limit: limit);
    },
  ),
];

Future<String> _findFiles(
  String root, {
  required String dir,
  required String pattern,
  required int limit,
}) async {
  if (ToolPolicy.hasExecutable('rg')) {
    final result = await _exec(root, 'rg', [
      '--files',
      dir,
      '-g',
      pattern,
      '--color',
      'never',
    ], timeout: const Duration(seconds: 60));
    if (result.timedOut) return '错误：查找超时';
    if (result.exitCode != 0 && result.exitCode != 1) return _format(result);
    final lines = result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(limit)
        .toList();
    if (lines.isEmpty) return '未找到匹配「$pattern」的文件';
    return lines.map((line) => _relative(root, line)).join('\n');
  }
  // 回退：Dart 遍历 + 简单 glob
  final regex = RegExp(
    '^${pattern.replaceAll('.', r'\.').replaceAll('*', '.*').replaceAll('?', '.')}\$',
  );
  final results = <String>[];
  final base = Directory(dir);
  if (!await base.exists()) return '错误：目录不存在';
  try {
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (results.length >= limit) break;
      if (entity is! File) continue;
      final relative = _relative(root, entity.path);
      if (_skipDirs.any((name) => relative.split('/').contains(name))) continue;
      if (regex.hasMatch(p.basename(entity.path))) results.add(relative);
    }
  } catch (e) {
    return '错误：$e';
  }
  return results.isEmpty ? '未找到匹配「$pattern」的文件' : results.join('\n');
}

const Set<String> _skipDirs = {
  '.git',
  '.dart_tool',
  '.idea',
  'build',
  'node_modules',
  '.gradle',
  'dist',
  'out',
};

// -----------------------------------------------------------------------------
// 质量：分析 / 格式化 / 测试 / 本地构建
// -----------------------------------------------------------------------------

List<McpTool> _qualityTools(McpToolbox box) => [
  McpTool(
    name: 'analyze_project',
    description: '对项目做静态分析（flutter analyze / dart analyze / tsc --noEmit）。',
    parameters: _object({}),
    execute: (_) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final tm = ToolchainManager.instance;
      await tm.initialize();
      if (File(p.join(root, 'pubspec.yaml')).existsSync()) {
        final flutter = tm.resolveExecutable(
          ToolchainKind.flutter,
          projectPath: root,
        );
        if (flutter != null) {
          return _run(root, flutter, const [
            'analyze',
          ], timeout: const Duration(minutes: 5));
        }
        final dart = tm.resolveExecutable(
          ToolchainKind.dart,
          projectPath: root,
        );
        if (dart != null) {
          return _run(root, dart, const [
            'analyze',
          ], timeout: const Duration(minutes: 5));
        }
      }
      if (File(p.join(root, 'package.json')).existsSync()) {
        if (File(p.join(root, 'tsconfig.json')).existsSync()) {
          return _run(root, 'npx', const [
            'tsc',
            '--noEmit',
          ], timeout: const Duration(minutes: 5));
        }
        final scripts = _packageScripts(root);
        for (final name in const ['lint', 'typecheck', 'check']) {
          if (scripts.containsKey(name)) {
            return _run(root, 'npm', [
              'run',
              name,
            ], timeout: const Duration(minutes: 5));
          }
        }
      }
      return '错误：无法识别项目类型（缺少 pubspec.yaml / package.json）';
    },
  ),
  McpTool(
    name: 'format_file',
    description: '格式化单个文件（Dart 用 dart format，前端文件用 prettier）。',
    parameters: _object({'path': _string('文件路径（相对项目根）')}, required: ['path']),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      final file = File(target);
      if (!await file.exists()) return '错误：文件不存在 ${_relative(root, target)}';
      final before = await file.readAsString();
      final tm = ToolchainManager.instance;
      await tm.initialize();
      String command;
      List<String> cliArgs;
      if (target.endsWith('.dart')) {
        final dart = tm.resolveExecutable(
          ToolchainKind.dart,
          projectPath: root,
        );
        if (dart == null) return '错误：未找到 dart 可执行文件';
        command = dart;
        cliArgs = ['format', target];
      } else {
        command = 'npx';
        cliArgs = ['prettier', '--write', target];
      }
      final output = await _run(
        root,
        command,
        cliArgs,
        timeout: const Duration(minutes: 2),
      );
      if (output.startsWith('错误')) return output;
      final after = await file.readAsString();
      if (after == before) return '${_relative(root, target)} 无需格式化';
      AiChangeJournal.instance.record(
        kind: AiChangeKind.write,
        action: t('approval.write'),
        path: target,
        before: before,
        after: after,
      );
      box.editor.replaceContent(target, after);
      return '已格式化 ${_relative(root, target)}，改动已登记，可随时撤回';
    },
  ),
  McpTool(
    name: 'run_tests',
    description: '运行项目测试（自动识别 flutter test / npm test / pytest），超时 5 分钟。',
    parameters: _object({'target': _string('可选：指定测试文件或模式')}),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = (args['target'] as String? ?? '').trim();
      const timeout = Duration(minutes: 5);
      final tm = ToolchainManager.instance;
      await tm.initialize();
      if (File(p.join(root, 'pubspec.yaml')).existsSync()) {
        final flutter = tm.resolveExecutable(
          ToolchainKind.flutter,
          projectPath: root,
        );
        if (flutter != null) {
          return _run(root, flutter, [
            'test',
            if (target.isNotEmpty) target,
          ], timeout: timeout);
        }
        final dart = tm.resolveExecutable(
          ToolchainKind.dart,
          projectPath: root,
        );
        if (dart != null) {
          return _run(root, dart, [
            'test',
            if (target.isNotEmpty) target,
          ], timeout: timeout);
        }
      }
      if (_packageScripts(root).containsKey('test')) {
        return _run(root, 'npm', ['test', '--silent'], timeout: timeout);
      }
      if (File(p.join(root, 'pytest.ini')).existsSync() ||
          File(p.join(root, 'pyproject.toml')).existsSync() ||
          Directory(p.join(root, 'tests')).existsSync()) {
        return _run(root, Platform.isWindows ? 'python' : 'python3', [
          '-m',
          'pytest',
          '-q',
          if (target.isNotEmpty) target,
        ], timeout: timeout);
      }
      return '错误：未识别到测试命令';
    },
  ),
  McpTool(
    name: 'local_build',
    description:
        '在本地执行构建 / 运行 / 测试 / 分析任务，返回各步骤结果与产物。'
        'target 可选值见项目构建页，如 flutter.web、flutter.apk、node.build。',
    parameters: _object(
      {
        'target': _string('构建目标 id'),
        'kind': _string('build / run / test / analyze，默认 build'),
      },
      required: ['target'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final targetId = (args['target'] as String? ?? '').trim();
      final target = localBuildTargets
          .where((item) => item.id == targetId)
          .firstOrNull;
      if (target == null) {
        return '错误：未知构建目标 $targetId'
            '（可用：${localBuildTargets.map((item) => item.id).join(', ')}）';
      }
      if (!target.availableOnHost) return '错误：${target.unavailableReason}';
      final kind =
          LocalTaskKind.values
              .where(
                (item) => item.name == (args['kind'] as String? ?? 'build'),
              )
              .firstOrNull ??
          LocalTaskKind.build;
      final service = LocalBuildService();
      try {
        final steps = await service.plan(
          projectPath: root,
          target: target,
          kind: kind,
        );
        await ToolchainManager.instance.initialize();
        final task = LocalBuildTask(
          id: 'mcp-${DateTime.now().millisecondsSinceEpoch}',
          projectPath: root,
          target: target,
          kind: kind,
          steps: steps,
        );
        final logs = StringBuffer();
        final exitCode = await service
            .execute(
              task: task,
              environment: ToolchainManager.instance
                  .environment(projectPath: root)
                  .build(),
              onLog: (line) {
                logs.writeln(line);
              },
              onUpdate: () {},
            )
            .timeout(
              const Duration(minutes: 30),
              onTimeout: () {
                service.cancel();
                return -2;
              },
            );
        final artifacts = await const ArtifactResolver().resolve(
          projectPath: root,
          target: target,
        );
        final buffer = StringBuffer()
          ..writeln('目标：${target.label}（${target.id}）')
          ..writeln('结果：${exitCode == 0 ? '成功' : '失败（exit $exitCode）'}');
        for (final step in task.steps) {
          buffer.writeln(
            '- ${step.name}: ${step.status.name}'
            '${step.exitCode == null ? '' : '（exit ${step.exitCode}）'}',
          );
        }
        if (artifacts.isNotEmpty) {
          buffer.writeln('产物：');
          for (final artifact in artifacts) {
            buffer.writeln(
              '- ${_relative(root, artifact.path)}'
              '（${formatBytes(artifact.sizeBytes)}）',
            );
          }
        }
        buffer.writeln('日志（尾部）：');
        buffer.write(ToolPolicy.truncate(logs.toString(), 12000));
        return ToolPolicy.truncate(buffer.toString());
      } on LocalBuildException catch (e) {
        return '错误：$e';
      } catch (e) {
        return '错误：$e';
      }
    },
  ),
];

Map<String, String> _packageScripts(String root) {
  final file = File(p.join(root, 'package.json'));
  if (!file.existsSync()) return const {};
  try {
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map) return const {};
    final scripts = data['scripts'];
    if (scripts is! Map) return const {};
    return scripts.map((key, value) => MapEntry('$key', '$value'));
  } catch (e) {
    debugLog('解析 package.json 失败：$e');
    return const {};
  }
}

// -----------------------------------------------------------------------------
// LSP 桥接
// -----------------------------------------------------------------------------

List<McpTool> _lspTools(McpToolbox box) => [
  McpTool(
    name: 'lsp_diagnostics',
    description: '获取文件的语义诊断（Dart 语言服务），返回 行:列 级别 信息。',
    parameters: _object({'path': _string('文件路径（相对项目根）')}, required: ['path']),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      final session = await _lspSession(box, target);
      if (session == null) return _lspUnavailable;
      for (var i = 0; i < 25; i++) {
        final diagnostics = session.diagnostics[target];
        if (diagnostics != null) {
          if (diagnostics.isEmpty) return '${_relative(root, target)}：无诊断问题';
          return diagnostics
              .map(
                (item) =>
                    '${_relative(root, target)}:'
                    '${item.range.start.line + 1}:'
                    '${item.range.start.character + 1} '
                    '${_severityLabel(item.severity)} ${item.message}',
              )
              .join('\n');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return '（语言服务暂未返回诊断，请稍后重试）';
    },
  ),
  McpTool(
    name: 'lsp_definition',
    description: '查找符号定义位置（1 基行/列）。',
    parameters: _object(
      {
        'path': _string('文件路径（相对项目根）'),
        'line': _integer('行号（从 1 开始）'),
        'character': _integer('列号（从 1 开始）'),
      },
      required: ['path', 'line', 'character'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      final session = await _lspSession(box, target);
      if (session == null) return _lspUnavailable;
      final locations = await session.definitionAt(target, _positionOf(args));
      if (locations.isEmpty) return '未找到定义';
      return locations.map((item) => _formatLocation(root, item)).join('\n');
    },
  ),
  McpTool(
    name: 'lsp_hover',
    description: '获取符号的悬停信息（类型 / 文档）。',
    parameters: _object(
      {
        'path': _string('文件路径（相对项目根）'),
        'line': _integer('行号（从 1 开始）'),
        'character': _integer('列号（从 1 开始）'),
      },
      required: ['path', 'line', 'character'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      final session = await _lspSession(box, target);
      if (session == null) return _lspUnavailable;
      final hover = await session.hoverAt(target, _positionOf(args));
      if (hover == null || hover.isEmpty) return '未获取到悬停信息';
      return ToolPolicy.truncate(hover.contents);
    },
  ),
  McpTool(
    name: 'lsp_rename',
    description: '按语言服务语义重命名符号（跨文件修改，改动登记可撤回）。',
    parameters: _object(
      {
        'path': _string('文件路径（相对项目根）'),
        'line': _integer('行号（从 1 开始）'),
        'character': _integer('列号（从 1 开始）'),
        'new_name': _string('新名称'),
      },
      required: ['path', 'line', 'character', 'new_name'],
    ),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      final newName = (args['new_name'] as String? ?? '').trim();
      if (newName.isEmpty) return '错误：new_name 不能为空';
      final session = await _lspSession(box, target);
      if (session == null) return _lspUnavailable;
      final edit = await session.renameAt(target, _positionOf(args), newName);
      if (edit == null || edit.changes.isEmpty) return '未生成重命名改动';
      final changed = await _applyWorkspaceEdit(box, edit);
      if (changed.isEmpty) return '重命名未产生实际改动';
      return '已重命名 $newName，修改文件：\n'
          '${changed.map((path) => '- ${_relative(root, path)}').join('\n')}';
    },
  ),
];

const String _lspUnavailable = '错误：语言服务未就绪（请确认已在桌面端打开项目，且设置中的 LSP 已启用）';

Future<LspSession?> _lspSession(McpToolbox box, String path) async {
  final manager = LspManager.instance;
  if (!manager.isReady) return null;
  final session = manager.sessionForPath(path);
  if (session == null) return null;
  final text = await _textFor(box, path);
  if (text == null) return null;
  session.openDocument(path, text);
  return session;
}

LspPosition _positionOf(Map<String, dynamic> args) {
  final line = ((args['line'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
  final character = ((args['character'] as num?)?.toInt() ?? 1).clamp(
    1,
    1 << 30,
  );
  return LspPosition(line - 1, character - 1);
}

String _formatLocation(String root, LspLocation location) {
  final path = pathForUri(location.uri);
  final display = path == null ? location.uri : _relative(root, path);
  return '$display:${location.range.start.line + 1}:'
      '${location.range.start.character + 1}';
}

String _severityLabel(int severity) => switch (severity) {
  1 => 'error',
  2 => 'warning',
  3 => 'info',
  _ => 'hint',
};

Future<List<String>> _applyWorkspaceEdit(
  McpToolbox box,
  LspWorkspaceEdit edit,
) async {
  final changed = <String>[];
  for (final entry in edit.changes.entries) {
    final path = pathForUri(entry.key);
    if (path == null || entry.value.isEmpty) continue;
    final before = await _textFor(box, path);
    if (before == null) continue;
    final updated = applyLspTextEdits(before, entry.value);
    if (updated == before) continue;
    final open = box.editor.openFiles
        .where((file) => file.path == path)
        .firstOrNull;
    if (open != null) {
      box.editor.replaceContent(path, updated);
    } else {
      try {
        await File(path).writeAsString(updated);
      } catch (e) {
        debugLog('写入 $path 失败：$e');
        continue;
      }
    }
    AiChangeJournal.instance.record(
      kind: AiChangeKind.write,
      action: t('approval.rename'),
      path: path,
      before: before,
      after: updated,
    );
    changed.add(path);
  }
  return changed;
}

// -----------------------------------------------------------------------------
// 环境与系统
// -----------------------------------------------------------------------------

List<McpTool> _miscTools(McpToolbox box) => [
  McpTool(
    name: 'environment_info',
    description: '查看宿主系统、Shell、工具链版本、Android SDK 与常用命令可用性。',
    parameters: _object({}),
    execute: (_) async {
      final root = _root(box);
      final tm = ToolchainManager.instance;
      await tm.initialize();
      final buffer = StringBuffer()
        ..writeln('系统：${DesktopPlatform.hostOs}（${DesktopPlatform.hostLabel}）')
        ..writeln('架构：$hostArchitecture')
        ..writeln('Shell：${DesktopPlatform.defaultShell}');
      if (root != null) buffer.writeln('项目：$root');
      buffer.writeln('工具链：');
      for (final kind in ToolchainKind.values) {
        final executable = tm.resolveExecutable(kind, projectPath: root);
        final version = tm.activeVersion(kind, projectPath: root);
        buffer.writeln(
          '- ${kind.label}: ${executable ?? '未找到'}'
          '${version == null ? '' : '（v$version）'}',
        );
      }
      final sdk = tm.environment(projectPath: root).build()['ANDROID_HOME'];
      buffer.writeln('Android SDK：${sdk ?? '未检测到'}');
      final commands = <String>[];
      for (final name in const ['git', 'rg', 'npx', 'uvx', 'python3']) {
        if (ToolPolicy.hasExecutable(name)) commands.add(name);
      }
      buffer.writeln('可用命令：${commands.isEmpty ? '无' : commands.join(', ')}');
      return buffer.toString();
    },
  ),
  McpTool(
    name: 'open_path',
    description: '在系统文件管理器中显示指定文件或目录。',
    parameters: _object({'path': _string('文件或目录路径（相对项目根，省略为项目根）')}),
    execute: (args) async {
      final root = _root(box);
      if (root == null) return '当前没有打开项目';
      final target = _resolve(box, args['path'] as String?);
      if (target == null) return '错误：路径超出项目范围';
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) {
        return '错误：路径不存在 ${_relative(root, target)}';
      }
      await DesktopPlatform.revealInFileManager(target);
      return '已在文件管理器中显示 ${_relative(root, target)}';
    },
  ),
];

// -----------------------------------------------------------------------------
// 命令执行
// -----------------------------------------------------------------------------

class _ExecResult {
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  const _ExecResult({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });
}

Future<_ExecResult> _exec(
  String root,
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final command = [executable, ...args].join(' ');
  final denial = ToolPolicy.validateCommand(command);
  if (denial != null) {
    return _ExecResult(
      command: command,
      exitCode: 126,
      stdout: '',
      stderr: '命令被安全策略拒绝（$denial）',
    );
  }
  await ToolchainManager.instance.initialize();
  final environment = ToolchainManager.instance
      .environment(projectPath: root)
      .build();
  Process process;
  try {
    process = await Process.start(
      executable,
      args,
      workingDirectory: root,
      environment: environment,
      runInShell:
          Platform.isWindows && executable.toLowerCase().endsWith('.bat'),
    );
  } on ProcessException catch (e) {
    return _ExecResult(
      command: command,
      exitCode: 127,
      stdout: '',
      stderr: '无法执行 $executable：${e.message}',
    );
  }
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 忽略
    }
    exitCode = -1;
  }
  final stdoutText = await stdoutFuture;
  final stderrText = await stderrFuture;
  return _ExecResult(
    command: command,
    exitCode: exitCode,
    stdout: stdoutText,
    stderr: stderrText,
    timedOut: timedOut,
  );
}

Future<String> _run(
  String root,
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final result = await _exec(root, executable, args, timeout: timeout);
  return _format(result);
}

String _format(_ExecResult result) {
  if (result.timedOut) {
    return '错误：命令超时\n---\n\$ ${result.command}';
  }
  final output = '${result.stdout}${result.stderr}'.trim();
  if (result.exitCode == 127) {
    return '错误：${result.stderr}';
  }
  final body = output.isEmpty ? '(无输出)' : output;
  if (result.exitCode != 0) {
    return '错误：命令退出码 ${result.exitCode}\n\$ ${result.command}\n---\n'
        '${ToolPolicy.truncate(body)}';
  }
  return '\$ ${result.command}\n---\n${ToolPolicy.truncate(body)}';
}

// -----------------------------------------------------------------------------
// 路径 / 文本辅助
// -----------------------------------------------------------------------------

String? _root(McpToolbox box) => box.project.projectPath;

String? _resolve(McpToolbox box, String? value) {
  final root = _root(box);
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return root;
  if (p.isAbsolute(raw)) {
    final normalized = p.normalize(raw);
    if (root != null && !ToolPolicy.insideWorkspace(root, normalized)) {
      return null;
    }
    return normalized;
  }
  if (root == null) return null;
  return p.normalize(p.join(root, raw));
}

String _relative(String root, String path) =>
    p.relative(path, from: root).replaceAll(Platform.pathSeparator, '/');

Future<String?> _textFor(McpToolbox box, String path) async {
  final open = box.editor.openFiles
      .where((file) => file.path == path)
      .firstOrNull;
  if (open != null) return open.content;
  return _fileText(path);
}

Future<String?> _fileText(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (_) {
    return null;
  }
}

/// 从统一 diff 中解析 `+++ b/xxx` 形式的文件路径
Set<String> _patchPaths(String patch) {
  final result = <String>{};
  for (final match in RegExp(
    r'^\+\+\+ (?:b/)?(.+)$',
    multiLine: true,
  ).allMatches(patch)) {
    var value = match.group(1)!.trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty || value == '/dev/null') continue;
    result.add(value);
  }
  return result;
}

void debugLog(String message) => debugPrint('[desktop-tools] $message');

// -----------------------------------------------------------------------------
// JSON Schema 辅助
// -----------------------------------------------------------------------------

Map<String, dynamic> _object(
  Map<String, dynamic> properties, {
  List<String> required = const [],
}) => {'type': 'object', 'properties': properties, 'required': required};

Map<String, dynamic> _string(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, dynamic> _integer(String description) => {
  'type': 'integer',
  'description': description,
};

Map<String, dynamic> _boolean(String description) => {
  'type': 'boolean',
  'description': description,
};

Map<String, dynamic> _array(String description) => {
  'type': 'array',
  'items': {'type': 'string'},
  'description': description,
};
