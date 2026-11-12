import '../services/llm_service.dart';
import 'design_tools.dart';
import 'mcp_tools.dart';

/// 设计稿 AI Agent
///
/// 独立于代码编辑器 Agent 的一套 MCP：通过 [DesignToolkit] 直接编排设计稿，
/// 采用「思考 → 调工具 → 观察 → 继续」的循环。
class DesignAgentService {
  DesignAgentService(this.toolkit);

  final DesignToolkit toolkit;

  Future<String> run({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> history,
    void Function(String delta)? onDelta,
    void Function(String name, String summary)? onStep,
    bool Function()? isCancelled,
  }) async {
    final system = '你是 SLIPE 设计稿编排助手，负责用可视化有向图搭建项目蓝图。'
        '你可以使用 design_* 工具直接修改当前设计稿，修改会自动保存。\n'
        '规则：先用 design_state 查看现状；root/system/block 的 id 必须来自 '
        'design_list_payloads；新增端后保存返回的 node_id；为端挂载模块后再连线。\n'
        '完成后用简洁中文说明设计稿结构（端、模块、跳转关系）。\n\n'
        '${toolkit.summary}';
    final messages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: system),
      ...history,
    ];
    final steps = <AgentToolStep>[];
    final toolDefs =
        toolkit.tools.map((t) => t.toDefinition()).toList(growable: false);

    for (var round = 0; round < 40; round++) {
      if (isCancelled?.call() == true) return '已取消';
      Map<String, dynamic>? finalMessage;
      await for (final chunk in LlmService.instance.streamChatMessage(
        apiBase: apiBase,
        apiKey: apiKey,
        model: model,
        messages: messages,
        tools: toolDefs,
      )) {
        if (chunk.deltaText != null) onDelta?.call(chunk.deltaText!);
        if (chunk.finalMessage != null) finalMessage = chunk.finalMessage;
      }
      if (finalMessage == null) return '（模型没有返回内容）';
      final content = (finalMessage['content'] as String?) ?? '';
      final rawCalls = finalMessage['tool_calls'];
      final calls = rawCalls is List
          ? rawCalls
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const <Map<String, dynamic>>[];
      if (calls.isEmpty) {
        return content.trim().isEmpty ? '（模型没有返回内容）' : content;
      }
      messages.add(ChatMessage(
        role: ChatRole.assistant,
        content: content,
        toolCalls: calls,
      ));
      for (final call in calls) {
        if (isCancelled?.call() == true) return '已取消';
        final id = call['id']?.toString() ?? '';
        final fn = call['function'];
        final name = (fn is Map ? fn['name'] : null)?.toString() ?? '';
        final args = DesignToolkit.decodeArgs(fn is Map ? fn['arguments'] : null);
        final step = AgentToolStep(name, _summary(name, args), args: args);
        steps.add(step);
        onStep?.call(name, step.summary);
        final tool = toolkit.tools.where((t) => t.name == name).firstOrNull;
        final result = tool == null
            ? '错误：未知工具 $name'
            : await tool.execute(args);
        step
          ..result = result
          ..running = false;
        messages.add(ChatMessage.toolResult(
          toolCallId: id,
          name: name,
          content: result,
        ));
      }
    }
    return '设计稿编排步骤过多，已停止。可以继续发送指令继续完善。';
  }

  String _summary(String name, Map<String, dynamic> args) {
    final detail = args['spec_id'] ?? args['node_id'] ?? args['name'] ?? '';
    return detail.toString().isEmpty ? name : '$name · $detail';
  }
}
