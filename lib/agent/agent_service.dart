import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../providers/project_provider.dart';
import '../services/llm_service.dart';
import 'mcp_tools.dart';

/// Agent 运行结果
class AgentResult {
  final String content;
  final List<AgentToolStep> steps;

  /// 深度思考模型的思考过程（仅展示，不回传上游）
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
      _skillCache =
          '# SLIPE Agent\n'
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
    final projectPath = _project.projectPath;
    final hasProject = projectPath != null && projectPath.isNotEmpty;
    final root = hasProject ? projectPath : '（未挂载项目）';
    final payload = _project.payload;
    final extra = extraSkill.trim();
    final globalRules = hasProject
        ? ''
        : '# 全局助手边界\n'
              '- 当前是首页全局 AI，未挂载任何项目。\n'
              '- 不得声称已经读取、修改或构建本地项目；需要项目文件、终端、Git、LSP 或构建能力时，引导用户在首页挂载项目。\n'
              '- 可以正常通用对话，并使用已授权的连接器、联网搜索和全局 MCP / Skills。\n';
    return '$skill\n\n'
        '${extra.isEmpty ? '' : '# 用户导入的扩展 Skill\n$extra\n\n'}'
        '# 运行环境\n'
        '- 项目根目录：$root\n'
        '- 项目载荷：${payload.name}（${payload.id}）\n'
        '- 默认高亮语言：${payload.defaultLanguage}\n'
        '- 所有工具路径优先使用项目内相对路径。\n\n'
        '$globalRules';
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
    String? extraSystemPrompt,
    String? subAgentPrompt,
    bool planOnly = false,
    bool Function()? isCancelled,
  }) async {
    var system = await buildSystemPrompt(extraSkill: extraSystemPrompt ?? '');
    if (subAgentPrompt != null && subAgentPrompt.trim().isNotEmpty) {
      system += '\n# 子代理职责\n${subAgentPrompt.trim()}\n';
    }
    system +=
        '\n# 任务执行方式\n'
        '- 开始执行前，先用 update_todo_list 把任务拆成 3-7 个阶段 TODO；\n'
        '- 按 TODO 逐步执行，每完成一个阶段立刻调用 update_todo_list 更新状态；\n'
        '- 需求明确时直接执行，不要为了提问而提问；仅当出现明显需求冲突、'
        '关键技术决策缺失或信息不足时，才调用 ask_user 向用户提问；\n'
        '- 回答用户时简洁说明改了什么、下一步做什么。\n'
        '\n# 终端与长驻进程\n'
        '- 执行 npm run dev、python app.py 等不会自动退出的命令时，把 '
        'timeout_seconds 设为 20-60 秒；超时返回「仍在运行 + session_id」是正常结果，'
        '不要反复重跑同一条命令。\n'
        '- 之后可用 terminal_read 查看新日志、terminal_wait 继续等待、'
        'terminal_send_input 回答 y/n / 填写内容 / 发送 ctrl+c 等组合键，'
        '不再需要时用 terminal_close 结束。\n'
        '- 长驻进程启动后，可以先用其它工具继续推进工作，之后再回来读取结果。\n'
        '\n# 子代理\n'
        '- 当任务可以拆成互不依赖的调研、批量修改或验证子任务时，'
        '可用 spawn_subagent 派生一个子代理并行处理，主代理继续推进主线。\n'
        '- 子代理不会向用户提问，只返回执行摘要；给它写清目标、范围与验收标准。\n';
    if (planOnly) {
      system +=
          '\n# 计划模式（/plan）\n'
          '用户现在只需要一份实施计划，不要做任何实际修改：\n'
          '- 可以先用 ask_user 澄清关键决策（技术方案、范围、兼容性等），一次问 1-3 个问题；\n'
          '- 可以使用读取类工具（读文件、列目录、搜索代码）来了解现状；\n'
          '- 禁止调用任何写入/修改/删除/构建/终端类工具，第三方 MCP 工具也全部禁用；\n'
          '- 计划写好后必须调用 submit_plan，把规划文档（目标 → 现状分析 → '
          '分步实施计划 → 涉及文件 → 风险与确认点）写入临时 Markdown 并发起确认；\n'
          '- 只有用户在确认卡片上点击「执行计划」后，才允许开始实际修改。\n';
    }
    final systemContent = system;
    final messages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: systemContent),
      ...history,
    ];
    final steps = <AgentToolStep>[];
    final reasoning = StringBuffer();
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
          onReasoning: (text) {
            reasoning.write(text);
            onReasoning?.call(text);
          },
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
          return AgentResult(text, steps, reasoning: reasoning.toString());
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
          return AgentResult(text, steps, reasoning: reasoning.toString());
        }
        return AgentResult(
          content.trim().isEmpty ? '（模型没有返回内容）' : content,
          steps,
          reasoning: reasoning.toString(),
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
        final name =
            (function is Map ? function['name'] : null)?.toString() ?? '';
        final rawArgs = function is Map ? function['arguments'] : null;
        final args = _decodeArgs(rawArgs);

        final step = AgentToolStep(name, _summarize(name, args), args: args);
        steps.add(step);
        onStep?.call(step);

        final result = await toolbox.execute(name, args);
        // 用户确认计划后，本次运行立即退出计划模式，允许继续执行写操作
        if (name == 'submit_plan' && result.startsWith('PLAN_CONFIRMED')) {
          planOnly = false;
        }
        // 工具结果回填到 step，供对话流显式展示
        step
          ..result = result
          ..running = false;
        onStep?.call(step);

        messages.add(
          ChatMessage.toolResult(toolCallId: id, name: name, content: result),
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
              reasoning: reasoning.toString(),
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
