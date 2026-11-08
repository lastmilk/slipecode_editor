import '../agent/mcp_tools.dart';

/// AI 回复消息内的渲染分段类型
///
/// 一条 assistant 消息按时间顺序由多个分段组成：
/// 正文段落、思考过程块、工具调用批次（如「执行 2 条命令」）交替出现。
enum ChatSegmentKind { text, reasoning, tools }

/// 单个渲染分段
class ChatSegment {
  ChatSegment._(this.kind, {String text = '', List<AgentToolStep>? steps})
    : text = text,
      steps = steps ?? [];

  factory ChatSegment.text([String text = '']) =>
      ChatSegment._(ChatSegmentKind.text, text: text);

  factory ChatSegment.reasoning([String text = '']) =>
      ChatSegment._(ChatSegmentKind.reasoning, text: text);

  factory ChatSegment.tools(List<AgentToolStep> steps) =>
      ChatSegment._(ChatSegmentKind.tools, steps: steps);

  final ChatSegmentKind kind;

  /// text / reasoning 分段的文本内容
  String text;

  /// tools 分段的工具调用步骤
  final List<AgentToolStep> steps;

  bool get isText => kind == ChatSegmentKind.text;
  bool get isReasoning => kind == ChatSegmentKind.reasoning;
  bool get isTools => kind == ChatSegmentKind.tools;

  Map<String, dynamic> toJson() {
    switch (kind) {
      case ChatSegmentKind.text:
        return {'k': 'text', 't': text};
      case ChatSegmentKind.reasoning:
        return {'k': 'reasoning', 't': text};
      case ChatSegmentKind.tools:
        return {
          'k': 'tools',
          'steps': steps
              .map(
                (s) => {
                  'tool': s.tool,
                  'summary': s.summary,
                  'result': s.result,
                },
              )
              .toList(),
        };
    }
  }

  factory ChatSegment.fromJson(Map<String, dynamic> json) {
    switch (json['k']) {
      case 'reasoning':
        return ChatSegment.reasoning((json['t'] ?? '').toString());
      case 'tools':
        final raw = json['steps'];
        final steps = raw is List
            ? raw
                  .whereType<Map>()
                  .map(
                    (e) => AgentToolStep(
                      (e['tool'] ?? '').toString(),
                      (e['summary'] ?? '').toString(),
                      result: (e['result'] ?? '').toString(),
                      running: false,
                    ),
                  )
                  .toList()
            : <AgentToolStep>[];
        return ChatSegment.tools(steps);
      default:
        return ChatSegment.text((json['t'] ?? '').toString());
    }
  }

  /// 从 JSON 列表还原分段
  static List<ChatSegment>? listFromJson(Object? raw) {
    if (raw is! List) return null;
    final segments = raw
        .whereType<Map>()
        .map((e) => ChatSegment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return segments.isEmpty ? null : segments;
  }
}
