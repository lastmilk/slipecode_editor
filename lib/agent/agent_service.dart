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

/// 用户取消了 Agent 运行
class AgentCancelled implements Exception {
  const AgentCancelled();

  @override
  String toString() => '已取消';
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
  ///
  /// 不限制工具调用步数：循环会一直执行到模型不再发起工具调用、
  /// 或用户取消、或检测到完全重复的调用（防止模型原地打转）。
  Future<AgentResult> run({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> history,
    void Function(AgentToolStep step)? onStep,
    void Function(String delta)? onDelta,
    bool Function()? isCancelled,
  }) async {
    final system = await buildSystemPrompt();
    final messages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: system),
      ...history,
    ];
    final steps = <AgentToolStep>[];
    String? lastSignature;
    var repeatCount = 0;

    while (true) {
      if (isCancelled?.call() == true) throw const AgentCancelled();
      Map<String, dynamic> reply;
      try {
        reply = await _streamOnce(
          apiBase: apiBase,
          apiKey: apiKey,
          model: model,
          messages: messages,
          onDelta: onDelta,
        );
      } catch (e) {
        // 部分模型不支持 tools / 流式：首轮失败时退回普通对话
        if (steps.isEmpty && e is! AgentCancelled) {
          final text = await LlmService.instance.chat(
            apiBase: apiBase,
            apiKey: apiKey,
            model: model,
            messages: messages,
          );
          onDelta?.call(text);
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
        if (content.trim().isEmpty && steps.isEmpty) {
          // 流式返回为空：退回非流式再试一次
          final text = await LlmService.instance.chat(
            apiBase: apiBase,
            apiKey: apiKey,
            model: model,
            messages: messages,
          );
          onDelta?.call(text);
          return AgentResult(text, steps);
        }
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
        if (isCancelled?.call() == true) throw const AgentCancelled();
        final id = call['id']?.toString() ?? '';
        final function = call['function'];
        final name = (function is Map ? function['name'] : null)?.toString() ?? '';
        final rawArgs = function is Map ? function['arguments'] : null;
        final args = _decodeArgs(rawArgs);

        final step = AgentToolStep(name, _summarize(name, args), args: args);
        steps.add(step);
        onStep?.call(step);

        final result = await toolbox.execute(name, args);
        // 工具结果回填到 step，供对话流显式展示
        step
          ..result = result
          ..running = false;
        onStep?.call(step);

        messages.add(
          ChatMessage.toolResult(
            toolCallId: id,
            name: name,
            content: result,
          ),
        );

        // 完全重复的调用（同工具、同参数、同结果）连续出现时判定为原地打转
        final signature = '$name|${jsonEncode(args)}|$result';
        if (signature == lastSignature) {
          repeatCount++;
          if (repeatCount >= 3) {
            return AgentResult(
              '检测到工具调用重复执行且结果未变化，已自动停止。'
              '请查看已完成的修改，或换一种说法继续描述需求。',
              steps,
            );
          }
        } else {
          lastSignature = signature;
          repeatCount = 0;
        }
      }
    }
  }

  /// 单轮流式调用，返回完整的 assistant message（含 tool_calls）
  Future<Map<String, dynamic>> _streamOnce({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    void Function(String delta)? onDelta,
  }) async {
    Map<String, dynamic>? finalMessage;
    await for (final chunk in LlmService.instance.streamChatMessage(
      apiBase: apiBase,
      apiKey: apiKey,
      model: model,
      messages: messages,
      tools: toolbox.definitions,
    )) {
      if (chunk.deltaText != null) onDelta?.call(chunk.deltaText!);
      if (chunk.finalMessage != null) finalMessage = chunk.finalMessage;
    }
    if (finalMessage == null) {
      throw const LlmException('LLM 未返回内容');
    }
    return finalMessage;
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
