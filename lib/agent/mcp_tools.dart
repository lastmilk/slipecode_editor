import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/ai_change_journal.dart';
import '../services/ai_connector_service.dart';
import '../services/agent_permission_service.dart';
import '../services/dart_class_template.dart';
import '../services/desktop_platform.dart';
import '../services/desktop_terminal_service.dart';
import '../services/external_mcp_manager.dart';
import '../services/file_service.dart';
import '../services/tool_policy.dart';
import '../services/toolchain/toolchain_manager.dart';
import '../services/video_editor_service.dart';
import '../services/video_render_service.dart';
import 'desktop_tools.dart';
import 'tool_contract.dart';

export 'tool_contract.dart' show McpTool;

/// 一条阶段任务（AI 在执行前先拆分 TODO，并逐步更新状态）
class AgentTodoItem {
  final String content;

  /// pending / in_progress / completed
  final String status;

  const AgentTodoItem({required this.content, this.status = 'pending'});

  bool get completed => status == 'completed';
  bool get inProgress => status == 'in_progress';

  factory AgentTodoItem.fromJson(Map<String, dynamic> json) => AgentTodoItem(
    content: (json['content'] ?? '').toString(),
    status: (json['status'] ?? 'pending').toString(),
  );
}

/// 一次工具调用的展示记录
///
/// [result] 保存工具返回给模型的原始文本，用于在对话流中显式展示执行结果。
class AgentToolStep {
  final String tool;
  final String summary;
  final Map<String, dynamic> args;

  /// 工具返回文本（执行完成后填充）
  String result;

  /// 是否仍在执行
  bool running;

  AgentToolStep(
    this.tool,
    this.summary, {
    this.args = const {},
    this.result = '',
    this.running = true,
  });

  /// 工具返回是否代表失败
  bool get failed => result.startsWith('错误');
}

/// 工具箱：Agent 可调用的全部本地工具
///
/// 工具直接操作项目文件，等价于 MCP Server 暴露的能力。
/// 桌面端额外挂载 [desktopTools]（git / 搜索 / 分析 / LSP / 本地构建）。
class McpToolbox {
  McpToolbox({
    required this.project,
    required this.editor,
    required this.build,
    required this.connectors,
    this.terminal,
  });

  final ProjectProvider project;
  final EditorProvider editor;
  final BuildProvider build;
  final ConnectorService connectors;

  /// 终端能力（仅桌面端本地 shell 可用时由 Agent 使用）
  final TerminalProvider? terminal;

  /// 第三方 MCP 工具（桌面环境可接入本地 / 远程 MCP Server）
  ExternalMcpManager? externalManager;

  /// 按指令临时注入的工具（/design、/search、/mcpadd）
  final List<McpTool> _extraTools = [];

  /// 替换本轮动态工具
  void setExtraTools(List<McpTool> tools) {
    _extraTools
      ..clear()
      ..addAll(tools);
  }

  /// 向用户提问（由 UI 弹卡片并返回答案）
  Future<String> Function(
    String question,
    List<String> options,
    bool allowCustom,
  )?
  onAskUser;

  /// 计划确认（写入临时 Markdown 后询问用户是否执行）
  Future<bool> Function(String title, String markdown)? onSubmitPlan;

  /// 派生一个子代理执行独立子任务（由 AiProvider 注入）
  Future<String> Function(String task, String? context)? onSpawnSubAgent;

  /// TODO 清单更新回调
  void Function(List<AgentTodoItem> todos)? onTodoUpdate;

  final FileService _fs = FileService();

  /// AI 改动默认直接落盘，但会登记到台账，用户可事后撤回
  final AiChangeJournal _journal = AiChangeJournal.instance;

  /// 供 LLM 使用的工具定义
  ///
  /// 终端工具仅在桌面端（本地 shell 可用）时暴露给模型。
  List<Map<String, dynamic>> get definitions => [
    ...[...tools, ..._extraTools, ...desktopTools, ...videoTools]
        .where((tool) => (_root ?? '').isNotEmpty || !_requiresProject(tool))
        .where(
          (tool) => !_terminalToolNames.contains(tool.name) || _terminalReady,
        )
        .where(
          (tool) => tool.name != 'spawn_subagent' || onSpawnSubAgent != null,
        )
        .map((tool) => tool.toDefinition()),
    ...connectors.availableTools.map((tool) => tool.toDefinition()),
    ...?externalManager?.definitions,
  ];

  /// 桌面专属工具（git / 搜索 / 分析 / LSP / 本地构建）；非桌面返回空
  late final List<McpTool> desktopTools = buildDesktopTools(this);

  /// VibeVideo 剪辑工具（仅桌面端；AI 通过它们操作剪辑工作台）
  late final List<McpTool> videoTools = _buildVideoTools();

  /// 写操作工具（/plan 计划模式下禁用）
  static const Set<String> writeToolNames = {
    'write_file',
    'replace_in_file',
    'create_file',
    'create_dart_class',
    'rename_file',
    'delete_file',
    'run_terminal_command',
    'terminal_send_input',
    'terminal_close',
    'spawn_subagent',
    'run_build',
    'video_import_asset',
    'video_add_clip',
    'video_update_clip',
    'video_remove_clip',
    'video_reorder_clips',
    'video_set_project',
    'video_export',
  };

  /// 无需挂载项目即可使用的工具（视频工作台可单独打开）。
  static const Set<String> _videoToolNames = {
    'video_project_state',
    'video_import_asset',
    'video_add_clip',
    'video_update_clip',
    'video_remove_clip',
    'video_reorder_clips',
    'video_set_project',
    'video_export',
  };

  static const Set<String> _globalInteractionTools = {
    'update_todo_list',
    'ask_user',
    'submit_plan',
  };

  /// 动态指令、外部 MCP 与连接器可全局使用；其余内置工具需要项目。
  bool _requiresProject(McpTool tool) {
    if (_videoToolNames.contains(tool.name)) return false;
    return !_extraTools.contains(tool) &&
        !_globalInteractionTools.contains(tool.name);
  }

  /// 判断工具是否属于写操作。
  /// 第三方 MCP 工具无法预知副作用，计划模式下一律视为写操作禁用。
  static bool isWriteTool(String name) =>
      writeToolNames.contains(name) ||
      name.startsWith(ExternalMcpManager.toolPrefix);

  /// 供 LLM 使用的工具定义；[planOnly] 为 true 时只保留读取类工具
  /// 以及提问 / TODO / 计划确认工具。
  List<Map<String, dynamic>> definitionsFor({bool planOnly = false}) {
    final all = definitions;
    return all.where((def) {
      final fn = def['function'];
      final name = fn is Map ? (fn['name'] ?? '').toString() : '';
      if (name == 'submit_plan') return planOnly;
      if (!planOnly) return true;
      if (name.startsWith(ConnectorService.toolPrefix)) {
        return connectors.isReadOnlyTool(name);
      }
      return !isWriteTool(name);
    }).toList();
  }

  bool get _terminalReady => terminal?.available ?? false;

  static const Set<String> _terminalToolNames = {
    'run_terminal_command',
    'terminal_read',
    'terminal_wait',
    'terminal_send_input',
    'terminal_list',
    'terminal_close',
  };

  Map<String, String> _terminalEnvironment() =>
      ToolchainManager.instance.environment(projectPath: _root).build();

  String? get _root => project.projectPath;

  /// 执行一次工具调用，返回给模型看的文本结果
  Future<String> execute(String name, Map<String, dynamic> args) async {
    if (name.startsWith(ExternalMcpManager.toolPrefix)) {
      final manager = externalManager;
      if (manager == null) return '错误：第三方 MCP 未初始化';
      return manager.execute(name, args);
    }
    if (name.startsWith(ConnectorService.toolPrefix)) {
      return connectors.execute(name, args);
    }
    final tool = [
      ...tools,
      ..._extraTools,
      ...desktopTools,
      ...videoTools,
    ].where((t) => t.name == name).firstOrNull;
    if (tool == null) return '错误：未知工具 $name';
    if ((_root ?? '').isEmpty && _requiresProject(tool)) {
      return '错误：请先在全局 AI 中挂载项目，再使用 $name';
    }
    final denial = await AgentPermissionService.instance.check(name, args);
    if (denial != null) {
      return '错误：$denial。请换一种方式，或先用 ask_user 询问用户。';
    }
    try {
      return await tool.execute(args);
    } catch (e) {
      return '错误：$e';
    }
  }

  // ---------------------------------------------------------------------------
  // 工具定义
  // ---------------------------------------------------------------------------

  late final List<McpTool> tools = [
    McpTool(
      name: 'get_project_info',
      description: '获取当前项目信息：路径、载荷（项目类型）、已打开的文件列表。',
      parameters: _object({}),
      execute: (_) async {
        if (_root == null) return '当前没有打开项目';
        final open = editor.openFiles.map((f) => _rel(f.path)).join(', ');
        return '项目路径：$_root\n'
            '载荷：${project.payload.name}（${project.payload.id}）\n'
            '默认语言：${project.payload.defaultLanguage}\n'
            '已打开文件：${open.isEmpty ? '无' : open}';
      },
    ),
    McpTool(
      name: 'list_files',
      description: '列出项目或指定目录下的文件与文件夹（用于了解项目结构）。',
      parameters: _object({
        'dir': _string('目录相对路径，默认项目根目录'),
        'depth': _integer('递归深度，默认 2'),
      }),
      execute: (args) async {
        if (_root == null) return '当前没有打开项目';
        final baseDir = _resolve(args['dir'] as String?) ?? _root!;
        final depth = (args['depth'] as num?)?.toInt() ?? 2;
        final buffer = StringBuffer();
        await _listDir(Directory(baseDir), '', depth, buffer);
        return buffer.isEmpty ? '（空目录）' : buffer.toString();
      },
    ),
    McpTool(
      name: 'read_file',
      description: '读取一个文件的完整内容。',
      parameters: _object({'path': _string('文件路径（相对或绝对）')}, required: ['path']),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        if (path == null) return '错误：缺少 path';
        if (!await File(path).exists()) return '错误：文件不存在 $path';
        final content = await _fs.readFile(path);
        return '文件：${_rel(path)}\n---\n$content';
      },
    ),
    McpTool(
      name: 'get_current_file',
      description: '读取编辑器当前打开文件的内容。用户说「这个文件」时使用。',
      parameters: _object({}),
      execute: (_) async {
        final active = editor.activeFile;
        if (active == null) return '当前没有打开任何文件';
        return '文件：${_rel(active.path)}\n---\n${active.content}';
      },
    ),
    McpTool(
      name: 'write_file',
      description: '覆盖写入整个文件。修改已有文件前应先 read_file 读取，保留无关内容。',
      parameters: _object(
        {'path': _string('文件路径'), 'content': _string('完整的新内容')},
        required: ['path', 'content'],
      ),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        if (path == null) return '错误：缺少 path';
        final content = args['content'] as String? ?? '';
        final existed = await File(path).exists();
        final old = existed ? await _fs.readFile(path) : '';
        if (old == content) return '文件内容未变化，无需写入 ${_rel(path)}';
        await _fs.writeFile(path, content);
        _journal.record(
          kind: existed ? AiChangeKind.write : AiChangeKind.create,
          action: existed ? t('approval.write') : t('approval.create'),
          path: path,
          before: existed ? old : null,
          after: content,
        );
        await _afterFileChanged(path);
        return '已写入 ${_rel(path)}（${content.length} 字符），'
            '改动已登记，可随时撤回';
      },
    ),
    McpTool(
      name: 'replace_in_file',
      description: '在文件中精确替换一段文本（只替换第一处匹配）。适合小改动。',
      parameters: _object(
        {
          'path': _string('文件路径'),
          'old_text': _string('需要被替换的原始文本（必须完全一致）'),
          'new_text': _string('替换后的文本'),
        },
        required: ['path', 'old_text', 'new_text'],
      ),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        if (path == null) return '错误：缺少 path';
        final oldText = args['old_text'] as String? ?? '';
        final newText = args['new_text'] as String? ?? '';
        if (oldText.isEmpty) return '错误：old_text 不能为空';
        final content = await _fs.readFile(path);
        if (!content.contains(oldText)) {
          return '错误：文件中未找到指定文本，请先 read_file 确认原文';
        }
        final updated = content.replaceFirst(oldText, newText);
        await _fs.writeFile(path, updated);
        _journal.record(
          kind: AiChangeKind.write,
          action: t('approval.replace'),
          path: path,
          before: content,
          after: updated,
        );
        await _afterFileChanged(path);
        return '已修改 ${_rel(path)}，改动已登记，可随时撤回';
      },
    ),
    McpTool(
      name: 'create_file',
      description: '新建文件（可同时写入初始内容）。',
      parameters: _object(
        {'path': _string('新文件路径'), 'content': _string('初始内容，可为空')},
        required: ['path'],
      ),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        if (path == null) return '错误：缺少 path';
        if (await File(path).exists()) return '错误：文件已存在 $path';
        final content = args['content'] as String? ?? '';
        await _fs.writeFile(path, content);
        _journal.record(
          kind: AiChangeKind.create,
          action: t('approval.create'),
          path: path,
          after: content,
        );
        await _afterFileChanged(path);
        return '已创建 ${_rel(path)}，改动已登记，可随时撤回';
      },
    ),
    McpTool(
      name: 'create_dart_class',
      description: '按模板生成 Dart 类文件。kind 可选：plain / statelessWidget / statefulWidget / service / model。',
      parameters: _object(
        {
          'dir': _string('目标目录，默认 lib'),
          'class_name': _string('类名（PascalCase）'),
          'kind': _string('模板种类，默认 plain'),
        },
        required: ['class_name'],
      ),
      execute: (args) async {
        final className = args['class_name'] as String? ?? '';
        if (className.isEmpty) return '错误：缺少 class_name';
        final rawKind = args['kind'] as String? ?? 'plain';
        final kind = DartClassKind.values.firstWhere(
          (k) => k.name == rawKind,
          orElse: () => DartClassKind.plain,
        );
        final dir = _resolve(args['dir'] as String?) ?? p.join(_root!, 'lib');
        final fileName = DartClassTemplate.fileNameFor(className);
        final path = p.join(dir, fileName);
        if (await File(path).exists()) return '错误：文件已存在 ${_rel(path)}';
        final content = DartClassTemplate.generate(kind, className);
        await _fs.writeFile(path, content);
        _journal.record(
          kind: AiChangeKind.create,
          action: t('approval.create'),
          path: path,
          after: content,
        );
        await _afterFileChanged(path);
        return '已创建 ${_rel(path)}（${kind.label}），改动已登记，可随时撤回';
      },
    ),
    McpTool(
      name: 'rename_file',
      description: '重命名文件或文件夹。',
      parameters: _object(
        {'path': _string('原路径'), 'new_name': _string('新名称（不含路径）')},
        required: ['path', 'new_name'],
      ),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        final newName = args['new_name'] as String? ?? '';
        if (path == null || newName.isEmpty) return '错误：缺少参数';
        final newPath = p.join(p.dirname(path), newName);
        await _fs.renameEntity(path, newName);
        _journal.record(
          kind: AiChangeKind.rename,
          action: t('approval.rename'),
          path: path,
          newPath: newPath,
        );
        final isDir = await Directory(newPath).exists();
        if (isDir) {
          editor.renameDirectory(path, newPath);
        } else {
          editor.renameOpenFile(path, newPath);
        }
        await project.refreshFileTree();
        return '已重命名为 ${_rel(newPath)}';
      },
    ),
    McpTool(
      name: 'delete_file',
      description: '删除文件或文件夹（不可撤销）。',
      parameters: _object({'path': _string('要删除的路径')}, required: ['path']),
      execute: (args) async {
        final path = _resolve(args['path'] as String?);
        if (path == null) return '错误：缺少 path';
        final isDir = await Directory(path).exists();
        final old = isDir ? null : await _fs.readFile(path);
        await _fs.deleteEntity(path);
        _journal.record(
          kind: AiChangeKind.delete,
          action: t('approval.delete'),
          path: path,
          before: old,
        );
        editor.closeFilesUnder(path);
        await project.refreshFileTree();
        return '已删除 ${_rel(path)}';
      },
    ),
    McpTool(
      name: 'search_code',
      description: '在项目内搜索文本（不区分大小写），返回 文件:行号:内容。',
      parameters: _object(
        {'query': _string('搜索关键字'), 'max_results': _integer('最多返回条数，默认 30')},
        required: ['query'],
      ),
      execute: (args) async {
        if (_root == null) return '当前没有打开项目';
        final query = (args['query'] as String? ?? '').toLowerCase();
        if (query.isEmpty) return '错误：query 不能为空';
        final limit = (args['max_results'] as num?)?.toInt() ?? 30;

        // 桌面端优先使用 ripgrep：更快且尊重 .gitignore
        if (ToolPolicy.hasExecutable('rg')) {
          try {
            final result = await Process.run(
              'rg',
              [
                '--line-number',
                '--no-heading',
                '--color',
                'never',
                '--ignore-case',
                '--max-count',
                '5',
                query,
                '.',
              ],
              workingDirectory: _root,
              runInShell: Platform.isWindows,
            );
            if (result.exitCode == 0 || result.exitCode == 1) {
              final lines = '${result.stdout}'
                  .split('\n')
                  .map((line) => line.replaceFirst(RegExp(r'^\./'), '').trim())
                  .where((line) => line.isNotEmpty)
                  .take(limit)
                  .toList();
              if (lines.isEmpty) return '未找到「$query」';
              return ToolPolicy.truncate(lines.join('\n'));
            }
          } catch (e) {
            debugPrint('ripgrep 搜索失败，回退内置遍历：$e');
          }
        }

        final results = StringBuffer();
        var count = 0;

        Future<void> walk(Directory dir) async {
          if (count >= limit) return;
          await for (final entity in dir.list(followLinks: false)) {
            if (count >= limit) return;
            final name = p.basename(entity.path);
            if (entity is Directory) {
              if (_skipDirs.contains(name) || name.startsWith('.')) continue;
              await walk(entity);
            } else if (entity is File) {
              if (_skipExts.contains(p.extension(name).toLowerCase())) continue;
              final stat = await entity.stat();
              if (stat.size > 512 * 1024) continue;
              final lines = await entity.readAsLines();
              for (var i = 0; i < lines.length && count < limit; i++) {
                if (lines[i].toLowerCase().contains(query)) {
                  results.writeln(
                    '${_rel(entity.path)}:${i + 1}: ${lines[i].trim()}',
                  );
                  count++;
                }
              }
            }
          }
        }

        await walk(Directory(_root!));
        return count == 0 ? '未找到「$query」' : results.toString();
      },
    ),
    McpTool(
      name: 'run_terminal_command',
      description:
          '在项目目录执行 shell 命令（桌面端 PTY）。命令在 timeout_seconds 内结束时返回输出与退出码；'
          '未结束（如 npm run dev、python app.py 等长驻进程）不会强制终止，而是返回 session_id，'
          '你可以继续用 terminal_read 查看输出、terminal_send_input 输入内容（y/n、组合键等），'
          '或先用其它工具做别的事，稍后再回来读取。',
      parameters: _object(
        {
          'command': _string('要执行的完整 shell 命令'),
          'timeout_seconds': {
            'type': 'integer',
            'description': '等待命令结束的最长秒数，默认 60，范围 5-600。超时后命令继续在后台运行。',
          },
          'session_id': _string('可选：在已有终端会话中执行（默认自动选择/新建 AI 终端）'),
          'new_session': {
            'type': 'boolean',
            'description': '是否强制新建一个终端会话，默认 false',
          },
        },
        required: ['command'],
      ),
      execute: (args) async {
        if (!_terminalReady) {
          return '错误：终端不可用（本地终端仅桌面端可用，移动端请使用云端构建）';
        }
        final command = args['command'] as String? ?? '';
        if (command.trim().isEmpty) return '错误：command 不能为空';
        final denial = ToolPolicy.validateCommand(command);
        if (denial != null) return '错误：命令被安全策略拒绝（$denial）';
        final rawTimeout = args['timeout_seconds'];
        final seconds = rawTimeout is num
            ? rawTimeout.toInt().clamp(5, 600)
            : 60;
        final requestedSession = (args['session_id'] ?? '').toString().trim();
        final result = await DesktopTerminalService.instance.runCommand(
          command,
          timeout: Duration(seconds: seconds),
          sessionId: requestedSession.isEmpty ? null : requestedSession,
          newSession: args['new_session'] == true,
          workingDirectory: _root,
          environment: _terminalEnvironment(),
        );
        final buffer = StringBuffer()
          ..writeln('命令：$command')
          ..writeln(
            result.running
                ? '会话：${result.sessionId}（仍在运行，已等待 ${seconds}s）'
                : '会话：${result.sessionId}（已结束，退出码 ${result.exitCode}）',
          )
          ..writeln('--- 输出 ---')
          ..write(result.output.trimRight());
        if (result.running) {
          buffer
            ..writeln()
            ..writeln(
              '提示：命令未在超时时间内结束，已保留在后台。'
              '可先做其它操作，之后用 terminal_read（session_id=${result.sessionId}）读取新输出；'
              '若命令等待输入，用 terminal_send_input 发送；不再需要时用 terminal_close 结束。',
            );
        }
        return ToolPolicy.truncate(buffer.toString());
      },
    ),
    McpTool(
      name: 'terminal_read',
      description:
          '读取终端会话自上次读取以来的新输出。用于命令超时后继续观察长驻进程，'
          '或查看交互式命令的提示符。',
      parameters: _object(
        {
          'session_id': _string('终端会话 id（run_terminal_command 返回）'),
          'max_chars': {
            'type': 'integer',
            'description': '最多返回的字符数，默认 8000',
          },
        },
        required: ['session_id'],
      ),
      execute: (args) async {
        if (!_terminalReady) return '错误：终端不可用';
        final id = (args['session_id'] ?? '').toString().trim();
        if (id.isEmpty) return '错误：session_id 不能为空';
        final rawMax = args['max_chars'];
        final maxChars = rawMax is num ? rawMax.toInt().clamp(1000, 50000) : 8000;
        final result = DesktopTerminalService.instance.readOutput(
          id,
          maxChars: maxChars,
        );
        final buffer = StringBuffer()
          ..writeln(
            result.running
                ? '会话 $id：运行中'
                : '会话 $id：已结束${result.exitCode == null ? '' : '（退出码 ${result.exitCode}）'}',
          )
          ..writeln(
            result.hasNewOutput ? '--- 新输出 ---' : '--- 最近输出（无新内容）---',
          )
          ..write(result.output.trimRight());
        return ToolPolicy.truncate(buffer.toString());
      },
    ),
    McpTool(
      name: 'terminal_wait',
      description:
          '继续等待某个终端会话的场景：最多等待 timeout_seconds，'
          '命令结束则返回退出码与新输出，仍未结束则返回当前输出。'
          '用于长驻命令超时后「再等一会儿」。',
      parameters: _object(
        {
          'session_id': _string('终端会话 id'),
          'timeout_seconds': {
            'type': 'integer',
            'description': '本次最多等待的秒数，默认 30，范围 5-300',
          },
        },
        required: ['session_id'],
      ),
      execute: (args) async {
        if (!_terminalReady) return '错误：终端不可用';
        final id = (args['session_id'] ?? '').toString().trim();
        if (id.isEmpty) return '错误：session_id 不能为空';
        final raw = args['timeout_seconds'];
        final seconds = raw is num ? raw.toInt().clamp(5, 300) : 30;
        final exited = await DesktopTerminalService.instance.waitForExit(
          id,
          timeout: Duration(seconds: seconds),
        );
        final result = DesktopTerminalService.instance.readOutput(id);
        final buffer = StringBuffer()
          ..writeln(
            exited
                ? '会话 $id 已结束${result.exitCode == null ? '' : '（退出码 ${result.exitCode}）'}'
                : '会话 $id 仍在运行（已再等待 ${seconds}s）',
          )
          ..writeln('--- 输出 ---')
          ..write(result.output.trimRight());
        return ToolPolicy.truncate(buffer.toString());
      },
    ),
    McpTool(
      name: 'terminal_send_input',
      description:
          '向运行中的终端发送输入，用于回答 y/n、填写交互式提示或发送组合键。'
          '例如 input="y"、input="生产环境"，或 keys="ctrl+c" 中断当前命令。',
      parameters: _object(
        {
          'session_id': _string('终端会话 id'),
          'input': _string('要输入的内容；也可传组合键别名：ctrl+c / ctrl+d / enter / esc / tab / up / down'),
          'enter': {
            'type': 'boolean',
            'description': '输入后是否自动回车，默认 true',
          },
        },
        required: ['session_id', 'input'],
      ),
      execute: (args) async {
        if (!_terminalReady) return '错误：终端不可用';
        final id = (args['session_id'] ?? '').toString().trim();
        final input = (args['input'] ?? '').toString();
        if (id.isEmpty) return '错误：session_id 不能为空';
        final ok = DesktopTerminalService.instance.sendInput(
          id,
          input,
          enter: args['enter'] != false,
        );
        if (!ok) return '错误：会话 $id 不存在或已退出，无法输入';
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final result = DesktopTerminalService.instance.readOutput(id);
        final buffer = StringBuffer()
          ..writeln('已向会话 $id 输入：${input.isEmpty ? '（回车）' : input}')
          ..writeln(result.running ? '会话：运行中' : '会话：已结束（退出码 ${result.exitCode}）')
          ..writeln('--- 最新输出 ---')
          ..write(result.output.trimRight());
        return ToolPolicy.truncate(buffer.toString());
      },
    ),
    McpTool(
      name: 'terminal_list',
      description: '列出当前所有终端会话及其运行状态，便于在多个终端之间定位。',
      parameters: _object({}),
      execute: (_) async {
        if (!_terminalReady) return '错误：终端不可用';
        final sessions = DesktopTerminalService.instance.sessions;
        if (sessions.isEmpty) return '当前没有终端会话';
        return sessions
            .map(
              (session) =>
                  '- ${session.id}｜${session.title}｜'
                  '${session.running ? '运行中' : '已退出(${session.exitCode})'}'
                  '${session.id == DesktopTerminalService.instance.activeSessionId ? '｜当前' : ''}',
            )
            .join('\n');
      },
    ),
    McpTool(
      name: 'terminal_close',
      description:
          '结束终端会话。默认 kill：终止进程但保留终端与历史输出；'
          'action=close 时同时移除该终端。',
      parameters: _object(
        {
          'session_id': _string('终端会话 id'),
          'action': _string('kill（默认）或 close'),
        },
        required: ['session_id'],
      ),
      execute: (args) async {
        if (!_terminalReady) return '错误：终端不可用';
        final id = (args['session_id'] ?? '').toString().trim();
        if (id.isEmpty) return '错误：session_id 不能为空';
        final close = (args['action'] ?? 'kill').toString() == 'close';
        if (close) {
          await DesktopTerminalService.instance.closeSession(id);
          return '已关闭并移除终端 $id';
        }
        await DesktopTerminalService.instance.stopSession(id);
        return '已结束终端 $id 的进程（历史输出仍保留）';
      },
    ),
    McpTool(
      name: 'spawn_subagent',
      description:
          '派生一个子代理，独立完成一个边界清晰的子任务（如「只调研某模块」「只补充测试」）。'
          '适合把可并行的调研、批量修改、验证工作拆出去，主代理继续处理主线。'
          '子代理不会向你提问，完成后返回要点汇报。',
      parameters: _object(
        {
          'task': _string('交给子代理的完整任务描述（目标、范围、验收标准）'),
          'context': _string('可选：相关背景，例如关键文件、已知结论、约束'),
        },
        required: ['task'],
      ),
      execute: (args) async {
        final task = (args['task'] ?? '').toString().trim();
        if (task.isEmpty) return '错误：task 不能为空';
        final runner = onSpawnSubAgent;
        if (runner == null) return '错误：当前环境不支持子代理';
        final context = (args['context'] ?? '').toString().trim();
        return runner(task, context.isEmpty ? null : context);
      },
    ),
    McpTool(
      name: 'run_build',
      description: '触发云端构建（GitHub Actions / Gitee Go），异步执行，立即返回。',
      parameters: _object({}),
      execute: (_) async {
        if (_root == null) return '当前没有打开项目';
        if (build.isRunning) return '构建已在进行中';
        unawaited(build.startBuild(projectDir: _root!));
        return '已触发云端构建，可在「构建」页面查看进度';
      },
    ),
    McpTool(
      name: 'update_todo_list',
      description:
          '创建或更新本次任务的阶段 TODO 清单。开始执行前先拆分 3-7 个阶段，'
          '每完成一个阶段就调用本工具更新状态（pending / in_progress / completed）。',
      parameters: _object(
        {
          'todos': {
            'type': 'array',
            'description': '完整的 TODO 列表（每次传入全部条目）',
            'items': {
              'type': 'object',
              'properties': {
                'content': _string('阶段描述'),
                'status': _string('pending / in_progress / completed'),
              },
              'required': ['content', 'status'],
            },
          },
        },
        required: ['todos'],
      ),
      execute: (args) async {
        final raw = args['todos'];
        final todos = <AgentTodoItem>[];
        if (raw is List) {
          for (final item in raw) {
            if (item is Map) {
              final content = (item['content'] ?? '').toString().trim();
              if (content.isEmpty) continue;
              final status = (item['status'] ?? 'pending').toString();
              todos.add(
                AgentTodoItem(
                  content: content,
                  status:
                      ['pending', 'in_progress', 'completed'].contains(status)
                      ? status
                      : 'pending',
                ),
              );
            }
          }
        }
        if (todos.isEmpty) return '错误：todos 不能为空';
        onTodoUpdate?.call(todos);
        final done = todos.where((t) => t.completed).length;
        return '任务清单已更新（$done/${todos.length} 完成）：\n'
            '${todos.map((t) => '- [${t.status}] ${t.content}').join('\n')}';
      },
    ),
    McpTool(
      name: 'ask_user',
      description:
          '向用户提问，用于关键技术决策或需求不明确时。提问会暂停任务，'
          '等待用户选择/输入后再继续。计划模式下应优先用于澄清需求。',
      parameters: _object(
        {
          'question': _string('要问用户的问题'),
          'options': {
            'type': 'array',
            'description': '可选项（0-5 个，可为空表示自由输入）',
            'items': {'type': 'string'},
          },
          'allow_custom': {
            'type': 'boolean',
            'description': '是否允许用户自由输入（默认 true）',
          },
        },
        required: ['question'],
      ),
      execute: (args) async {
        final question = (args['question'] ?? '').toString().trim();
        if (question.isEmpty) return '错误：question 不能为空';
        final ask = onAskUser;
        if (ask == null) return '错误：当前环境不支持向用户提问';
        final options = <String>[];
        final raw = args['options'];
        if (raw is List) {
          for (final item in raw) {
            final text = item.toString().trim();
            if (text.isNotEmpty) options.add(text);
          }
        }
        final allowCustom = args['allow_custom'] != false;
        final answer = await ask(question, options, allowCustom);
        return '用户回答：$answer';
      },
    ),
    McpTool(
      name: 'submit_plan',
      description:
          '计划模式下把规划文档写入临时 Markdown，并向用户发起「计划确认」。'
          '用户确认后返回 PLAN_CONFIRMED，即可开始执行；被拒绝时返回 PLAN_REJECTED。',
      parameters: _object(
        {'title': _string('计划标题'), 'markdown': _string('完整的 Markdown 规划文档')},
        required: ['title', 'markdown'],
      ),
      execute: (args) async {
        final title = (args['title'] ?? '').toString().trim();
        final markdown = (args['markdown'] ?? '').toString();
        if (markdown.trim().isEmpty) return '错误：markdown 不能为空';
        final submit = onSubmitPlan;
        if (submit == null) return '错误：当前环境不支持计划确认';
        final root = _root;
        if (root != null) {
          try {
            final dir = Directory(p.join(root, '.slipe', 'plans'));
            await dir.create(recursive: true);
            final name = 'plan_${DateTime.now().millisecondsSinceEpoch}.md';
            final header = '# ${title.isEmpty ? '实施计划' : title}\n\n';
            await File(p.join(dir.path, name))
                .writeAsString('$header$markdown', flush: true);
          } catch (_) {
            // 临时文档写入失败不影响确认流程
          }
        }
        final approved = await submit(title.isEmpty ? '实施计划' : title, markdown);
        return approved
            ? 'PLAN_CONFIRMED：用户已确认计划，请开始执行。'
            : 'PLAN_REJECTED：用户暂不执行该计划，请等待进一步指示。';
      },
    ),
    McpTool(
      name: 'download',
      description: '从外部 HTTP/HTTPS 链接下载资源到项目目录（默认 downloads/，单文件上限 50MB）。',
      parameters: _object(
        {
          'url': _string('下载地址（必须含 host 的 http/https URL）'),
          'path': _string('保存到项目内的相对路径，缺省为 downloads/<文件名>'),
        },
        required: ['url'],
      ),
      execute: (args) async {
        if (_root == null) return '当前没有打开项目';
        final url = Uri.tryParse((args['url'] ?? '').toString().trim());
        if (url == null ||
            !(url.scheme == 'http' || url.scheme == 'https') ||
            url.host.isEmpty) {
          return '错误：无效的下载 URL';
        }
        final custom = (args['path'] ?? '').toString().trim();
        final fileName = custom.isNotEmpty
            ? p.basename(custom)
            : (url.pathSegments.isNotEmpty &&
                      url.pathSegments.last.trim().isNotEmpty
                  ? url.pathSegments.last
                  : 'download_${DateTime.now().millisecondsSinceEpoch}');
        final relDir = custom.isNotEmpty ? p.dirname(custom) : 'downloads';
        final dir = Directory(p.join(_root!, relDir));
        await dir.create(recursive: true);
        final outPath = p.join(dir.path, fileName);
        final res = await http.get(url).timeout(const Duration(minutes: 2));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return '错误：下载失败（HTTP ${res.statusCode}）';
        }
        if (res.bodyBytes.length > 50 * 1024 * 1024) {
          return '错误：文件超过 50MB 限制';
        }
        await File(outPath).writeAsBytes(res.bodyBytes, flush: true);
        await project.refreshFileTree();
        return '已下载：${_rel(outPath)}（${res.bodyBytes.length} 字节）';
      },
    ),
  ];

  // ---------------------------------------------------------------------------
  // VibeVideo 剪辑工具
  // ---------------------------------------------------------------------------

  /// 构建视频剪辑工具（仅桌面端）。
  List<McpTool> _buildVideoTools() {
    if (!DesktopPlatform.isDesktop) return const [];
    final editor = VideoEditorService.instance;

    String describe(VideoProjectData project) {
      final buffer = StringBuffer()
        ..writeln('项目：${project.name}（${project.width}×${project.height}'
            ' @ ${project.fps.toStringAsFixed(0)}fps）')
        ..writeln('总时长：${project.totalDuration.toStringAsFixed(1)}s，'
            '片段 ${project.clips.length} 个，素材 ${project.assets.length} 个');
      if (project.assets.isNotEmpty) {
        buffer.writeln('素材：');
        for (final asset in project.assets) {
          buffer.writeln('  - ${asset.id}  ${asset.name}  '
              '(${videoAssetKindLabel(asset.kind)})');
        }
      }
      if (project.clips.isNotEmpty) {
        buffer.writeln('时间线：');
        var cursor = 0.0;
        for (final clip in project.clips) {
          buffer.writeln('  ${cursor.toStringAsFixed(1)}s  ${clip.id}  '
              '「${clip.title}」 ${clip.duration.toStringAsFixed(1)}s '
              '${clip.transition == 'none' ? '' : '[${clip.transition}]'}'
              '${clip.text.isEmpty ? '' : ' 字幕:${clip.text}'}');
          cursor += clip.duration;
        }
      }
      return buffer.toString();
    }

    return [
      McpTool(
        name: 'video_project_state',
        description: '读取当前 VibeVideo 项目状态：分辨率、时长、素材与时间线片段。'
            '操作剪辑前先调用它了解现状。',
        parameters: _object({}),
        execute: (_) async {
          final project = await editor.ensureOpen(_root);
          return describe(project);
        },
      ),
      McpTool(
        name: 'video_import_asset',
        description: '把本地图片/视频/音频导入 VibeVideo 素材库。返回素材 id。',
        parameters: _object(
          {
            'path': _string('素材文件绝对路径'),
            'name': _string('展示名，默认取文件名'),
          },
          required: ['path'],
        ),
        execute: (args) async {
          final path = (args['path'] ?? '').toString().trim();
          if (path.isEmpty) return '错误：缺少 path';
          if (!await File(path).exists()) return '错误：文件不存在 $path';
          await editor.ensureOpen(_root);
          final asset = editor.addAsset(
            path,
            name: (args['name'] ?? '').toString().trim().isEmpty
                ? null
                : args['name'].toString(),
          );
          if (asset == null) return '错误：导入素材失败';
          return '已导入素材 ${asset.id}（${asset.name}，'
              '${videoAssetKindLabel(asset.kind)}）';
        },
      ),
      McpTool(
        name: 'video_add_clip',
        description: '向时间线末尾追加片段。可用 asset_id 引用已有素材，'
            '或传 text 生成纯文本/字幕片段。',
        parameters: _object(
          {
            'asset_id': _string('素材 id（与 text 二选一）'),
            'text': _string('文本/字幕内容（不使用素材时）'),
            'title': _string('片段标题'),
            'duration': _string('时长（秒）'),
            'transition': _string('转场：none / fade / slide / zoom'),
          },
        ),
        execute: (args) async {
          await editor.ensureOpen(_root);
          final assetId = (args['asset_id'] ?? '').toString().trim();
          final text = (args['text'] ?? '').toString();
          final title = (args['title'] ?? '').toString();
          final duration = double.tryParse(
            (args['duration'] ?? '').toString().trim(),
          );
          final transition =
              (args['transition'] ?? 'none').toString().trim();

          if (assetId.isNotEmpty) {
            final clip = editor.addClip(
              assetId: assetId,
              title: title,
              duration: duration,
              transition: transition,
            );
            if (clip == null) return '错误：素材不存在 $assetId';
            return '已添加片段 ${clip.id}「${clip.title}」'
                '（${clip.duration.toStringAsFixed(1)}s）';
          }
          if (text.trim().isEmpty) {
            return '错误：请提供 asset_id 或 text';
          }
          final clip = editor.addTextClip(
            text: text,
            title: title,
            duration: duration ?? 4,
            transition: transition,
          );
          return '已添加文本片段 ${clip.id}「${clip.title}」';
        },
      ),
      McpTool(
        name: 'video_update_clip',
        description: '修改片段属性：标题、时长、素材起点、转场、音量、字幕文本。',
        parameters: _object(
          {
            'clip_id': _string('片段 id'),
            'title': _string('新标题'),
            'duration': _string('新时长（秒）'),
            'in_point': _string('素材起点（秒）'),
            'transition': _string('转场 none / fade / slide / zoom'),
            'volume': _string('音量 0~1'),
            'text': _string('字幕文本'),
          },
          required: ['clip_id'],
        ),
        execute: (args) async {
          await editor.ensureOpen(_root);
          final clipId = (args['clip_id'] ?? '').toString().trim();
          if (clipId.isEmpty) return '错误：缺少 clip_id';
          editor.updateClip(
            clipId,
            title: (args['title'] ?? '').toString().trim().isEmpty
                ? null
                : args['title'].toString(),
            duration: double.tryParse((args['duration'] ?? '').toString()),
            inPoint: double.tryParse((args['in_point'] ?? '').toString()),
            transition: (args['transition'] ?? '').toString().trim().isEmpty
                ? null
                : args['transition'].toString(),
            volume: double.tryParse((args['volume'] ?? '').toString()),
            text: args.containsKey('text') ? args['text'].toString() : null,
          );
          return '已更新片段 $clipId';
        },
      ),
      McpTool(
        name: 'video_remove_clip',
        description: '从时间线删除一个片段。',
        parameters: _object(
          {'clip_id': _string('片段 id')},
          required: ['clip_id'],
        ),
        execute: (args) async {
          await editor.ensureOpen(_root);
          final clipId = (args['clip_id'] ?? '').toString().trim();
          if (clipId.isEmpty) return '错误：缺少 clip_id';
          editor.removeClip(clipId);
          return '已删除片段 $clipId';
        },
      ),
      McpTool(
        name: 'video_reorder_clips',
        description: '按给定顺序重排时间线（传全部片段 id）。',
        parameters: _object(
          {
            'clip_ids': {
              'type': 'array',
              'description': '完整的有序片段 id 列表',
              'items': {'type': 'string'},
            },
          },
          required: ['clip_ids'],
        ),
        execute: (args) async {
          await editor.ensureOpen(_root);
          final raw = args['clip_ids'];
          final ids = raw is List
              ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
              : const <String>[];
          if (ids.isEmpty) return '错误：clip_ids 不能为空';
          editor.reorderClips(ids);
          return '时间线已重排为：${ids.join(' → ')}';
        },
      ),
      McpTool(
        name: 'video_set_project',
        description: '设置视频项目名称、分辨率、帧率与背景色。',
        parameters: _object(
          {
            'name': _string('项目名称'),
            'width': _integer('画布宽度，如 1920'),
            'height': _integer('画布高度，如 1080'),
            'fps': _string('帧率，如 30'),
            'background': _string('背景色，如 #0A0A0C'),
          },
        ),
        execute: (args) async {
          await editor.ensureOpen(_root);
          final name = (args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) editor.renameProject(name);
          editor.setResolution(
            width: (args['width'] as num?)?.toInt(),
            height: (args['height'] as num?)?.toInt(),
          );
          final fps = double.tryParse((args['fps'] ?? '').toString());
          if (fps != null) editor.setFps(fps);
          final bg = (args['background'] ?? '').toString().trim();
          if (bg.isNotEmpty) editor.setBackground(bg);
          return '项目设置已更新：${describe(editor.project!)}';
        },
      ),
      McpTool(
        name: 'video_export',
        description: '导出当前时间线：生成合成工程（index.html/project.json/render.sh），'
            '并在可用时用 HyperFrames / ffmpeg 输出成片。',
        parameters: _object({}),
        execute: (_) async {
          final project = await editor.ensureOpen(_root);
          if (project.clips.isEmpty) return '错误：时间线为空，无法导出';
          final result = await VideoRenderService.instance.render(
            project,
            rootPath: editor.rootPath,
          );
          return '${result.message}'
              '${result.outputFile == null ? '' : '\n输出文件：${result.outputFile}'}'
              '${result.outputDir == null ? '' : '\n工程目录：${result.outputDir}'}';
        },
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // 辅助
  // ---------------------------------------------------------------------------

  static const Set<String> _skipDirs = {
    '.git',
    '.idea',
    '.dart_tool',
    '.gradle',
    'build',
    'node_modules',
    '.cxx',
    'dist',
  };

  static const Set<String> _skipExts = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.ico',
    '.zip',
    '.apk',
    '.aab',
    '.so',
    '.jar',
    '.ttf',
    '.otf',
  };

  Future<void> _afterFileChanged(String path) async {
    await project.refreshFileTree();
    await editor.reloadFile(path);
  }

  Future<void> _listDir(
    Directory dir,
    String indent,
    int depth,
    StringBuffer buffer, {
    int maxEntries = 200,
  }) async {
    if (depth < 0 || buffer.length > 20000) return;
    if (!await dir.exists()) return;
    final entities = await dir.list(followLinks: false).toList();
    entities.sort((a, b) {
      final aDir = a is Directory ? 0 : 1;
      final bDir = b is Directory ? 0 : 1;
      if (aDir != bDir) return aDir.compareTo(bDir);
      return p.basename(a.path).compareTo(p.basename(b.path));
    });
    for (final entity in entities.take(maxEntries)) {
      final name = p.basename(entity.path);
      if (_skipDirs.contains(name) || name.startsWith('.')) continue;
      if (entity is Directory) {
        buffer.writeln('$indent$name/');
        await _listDir(entity, '  $indent', depth - 1, buffer);
      } else {
        buffer.writeln('$indent$name');
      }
    }
  }

  /// 相对路径 → 绝对路径；绝对路径直接返回
  String? _resolve(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final value = path.trim();
    if (p.isAbsolute(value)) return value;
    final root = _root;
    if (root == null) return null;
    return p.join(root, value);
  }

  String _rel(String path) {
    final root = _root;
    if (root == null) return path;
    return p.relative(path, from: root).replaceAll(Platform.pathSeparator, '/');
  }

  static Map<String, dynamic> _object(
    Map<String, dynamic> properties, {
    List<String> required = const [],
  }) => {'type': 'object', 'properties': properties, 'required': required};

  static Map<String, dynamic> _string(String description) => {
    'type': 'string',
    'description': description,
  };

  static Map<String, dynamic> _integer(String description) => {
    'type': 'integer',
    'description': description,
  };
}
