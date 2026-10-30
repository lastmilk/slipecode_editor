import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../providers/project_provider.dart';
import '../services/llm_service.dart';
import 'mcp_tools.dart';

/// Agent 运行结果
class AgentResult {
  final String content;
  final List<AgentToolStep> steps;

  const AgentResult(this.content, this.steps);
}

/// Agent 服务
///
/// 以 Skill.md 为系统提示，配合 MCP 工具集执行「思考 → 调工具 → 观察 → 继续」的循环。
class AgentService {
  AgentService(this._project, this.toolbox);

  final ProjectProvider _project;
  final McpToolbox toolbox;

  static String? _skillCache;

  /// 读取内置 Skill.md（失败时退回精简提示）
  static Future<String> loadSkill() async {
    if (_skillCache != null) return _skillCache!;
    try {
      _skillCache = await rootBundle.loadString('assets/skills/skill.md');
    } catch (_) {
      _skillCache = '# SLIPE Agent\n'
          '你是 SLIPE 内置 Agent，可通过工具读写项目文件。'
          '优先使用工具直接修改文件，修改后简短说明。';
    }
    return _skillCache!;
  }

  /// 组装系统提示词
  Future<String> buildSystemPrompt() async {
    final skill = await loadSkill();
    final root = _project.projectPath ?? '（未打开项目）';
    final payload = _project.payload;
    return '$skill\n\n'
        '# 运行环境\n'
        '- 项目根目录：$root\n'
        '- 项目载荷：${payload.name}（${payload.id}）\n'
        '- 默认高亮语言：${payload.defaultLanguage}\n'
        '- 所有工具路径优先使用项目内相对路径。\n';
  }

  /// 运行 Agent 循环
  ///
  /// [history] 不含 system 消息。
  Future<AgentResult> run({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> history,
    void Function(AgentToolStep step)? onStep,
    int maxSteps = 6,
  }) async {
    final system = await buildSystemPrompt();
    final messages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: system),
      ...history,
    ];
    final steps = <AgentToolStep>[];

    for (var iteration = 0; iteration < maxSteps; iteration++) {
      Map<String, dynamic> reply;
      try {
        reply = await LlmService.instance.chatMessage(
          apiBase: apiBase,
          apiKey: apiKey,
          model: model,
          messages: messages,
          tools: toolbox.definitions,
        );
      } catch (e) {
        // 部分模型不支持 tools：首轮失败时退回普通对话
        if (iteration == 0 && steps.isEmpty) {
          final text = await LlmService.instance.chat(
            apiBase: apiBase,
            apiKey: apiKey,
            model: model,
            messages: messages,
          );
          return AgentResult(text, steps);
        }
        rethrow;
      }

      final content = (reply['content'] as String?) ?? '';
      final rawCalls = reply['tool_calls'];
      final calls = rawCalls is List
          ? rawCalls
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const <Map<String, dynamic>>[];

      // 没有工具调用：这就是最终回复
      if (calls.isEmpty) {
        return AgentResult(
          content.trim().isEmpty ? '（模型没有返回内容）' : content,
          steps,
        );
      }

      messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          content: content,
          toolCalls: calls,
        ),
      );

      for (final call in calls) {
        final id = call['id']?.toString() ?? '';
        final function = call['function'];
        final name = (function is Map ? function['name'] : null)?.toString() ?? '';
        final rawArgs = function is Map ? function['arguments'] : null;
        final args = _decodeArgs(rawArgs);

        final step = AgentToolStep(name, _summarize(name, args));
        steps.add(step);
        onStep?.call(step);

        final result = await toolbox.execute(name, args);
        messages.add(
          ChatMessage.toolResult(
            toolCallId: id,
            name: name,
            content: result,
          ),
        );
      }
    }

    return AgentResult(
      '已达到最大工具调用步数（$maxSteps），请查看已完成的修改或继续描述需求。',
      steps,
    );
  }

  Map<String, dynamic> _decodeArgs(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final text = raw.toString();
    if (text.isEmpty) return {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 参数不是合法 JSON 时按空参数执行，由工具返回错误
    }
    return {};
  }

  String _summarize(String name, Map<String, dynamic> args) {
    final path = args['path'] ?? args['dir'] ?? args['query'] ?? '';
    final className = args['class_name'] ?? '';
    final detail = path.toString().isNotEmpty
        ? path.toString()
        : className.toString();
    return detail.isEmpty ? name : detail;
  }
}
