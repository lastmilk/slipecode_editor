import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../providers/project_provider.dart';
import '../services/llm_service.dart';
import 'mcp_tools.dart';

/// Agent 运行结果
class AgentResult {
  final String content;
  final List<AgentToolStep> steps;

  /// 模型的思考过程（reasoning_content）
  final String reasoning;

  const AgentResult(this.content, this.steps, {this.reasoning = ''});
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
  ///
  /// [extraSkill] 为用户导入的外源 Skill 内容，追加到内置 Skill 之后。
  Future<String> buildSystemPrompt({String extraSkill = ''}) async {
    final skill = await loadSkill();
    final root = _project.projectPath ?? '（未打开项目）';
    final payload = _project.payload;
    final extra = extraSkill.trim();
    return '$skill\n\n'
        '${extra.isEmpty ? '' : '# 用户导入的扩展 Skill\n$extra\n\n'}'
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
    void Function(String delta)? onReasoning,
    String extraSystemPrompt = '',
    bool planOnly = false,
    bool Function()? isCancelled,
  }) async {
    var system = await buildSystemPrompt(extraSkill: extraSystemPrompt);
    if (planOnly) {
      system += '\n# 计划模式（/plan）\n'
          '用户现在只需要一份实施计划，不要做任何实际修改：\n'
          '- 可以使用读取类工具（读文件、列目录、搜索代码）来了解现状；\n'
          '- 禁止调用任何写入/修改/删除/构建/终端类工具，第三方 MCP 工具也全部禁用；\n'
          '- 输出格式：目标 → 现状分析 → 分步实施计划（含涉及文件与改动要点）→ 风险与确认点。\n'
          '计划要具体、可执行，等待用户确认后再进入实际执行。\n';
    }
    final messages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: system),
      ...history,
    ];
    final steps = <AgentToolStep>[];
    final reasoningBuffer = StringBuffer();
    String? lastSignature;
    var repeatCount = 0;

    void emitReasoning(String delta) {
      reasoningBuffer.write(delta);
      onReasoning?.call(delta);
    }

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
          onReasoning: emitReasoning,
          planOnly: planOnly,
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
          return AgentResult(text, steps, reasoning: reasoningBuffer.toString());
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
          return AgentResult(text, steps, reasoning: reasoningBuffer.toString());
        }
        return AgentResult(
          content.trim().isEmpty ? '（模型没有返回内容）' : content,
          steps,
          reasoning: reasoningBuffer.toString(),
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

        // 计划模式双保险：写工具已从定义中过滤，模型仍尝试调用时直接拦截
        if (planOnly && McpToolbox.isWriteTool(name)) {
          step
            ..result = '已跳过：计划模式下不执行写入类工具'
            ..running = false;
          onStep?.call(step);
          messages.add(
            ChatMessage.toolResult(
              toolCallId: id,
              name: name,
              content: '已跳过：计划模式下不执行写入类工具',
            ),
          );
          continue;
        }

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
              reasoning: reasoningBuffer.toString(),
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
    void Function(String delta)? onReasoning,
    bool planOnly = false,
  }) async {
    Map<String, dynamic>? finalMessage;
    await for (final chunk in LlmService.instance.streamChatMessage(
      apiBase: apiBase,
      apiKey: apiKey,
      model: model,
      messages: messages,
      tools: toolbox.definitionsFor(planOnly: planOnly),
    )) {
      if (chunk.deltaText != null) onDelta?.call(chunk.deltaText!);
      if (chunk.reasoningText != null) onReasoning?.call(chunk.reasoningText!);
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
