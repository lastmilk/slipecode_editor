import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_segment.dart';

/// 聊天消息角色
enum ChatRole { system, user, assistant, tool }

/// 单条聊天消息
class ChatMessage {
  final ChatRole role;
  final String content;

  /// role=tool 时对应的工具调用 id
  final String? toolCallId;

  /// role=tool 时的工具名
  final String? name;

  /// role=assistant 时返回的工具调用列表（OpenAI 格式）
  final List<Map<String, dynamic>>? toolCalls;

  /// 深度思考模型的思考过程（reasoning_content），仅用于展示，不回传上游
  final String? reasoning;

  /// 消息类型：normal（普通回复）| plan（/plan 计划模式产出）
  final String kind;

  /// assistant 消息的渲染分段（思考/正文/工具调用按时间顺序穿插），仅用于展示
  final List<ChatSegment>? segments;

  const ChatMessage({
    required this.role,
    required this.content,
    this.toolCallId,
    this.name,
    this.toolCalls,
    this.reasoning,
    this.kind = 'normal',
    this.segments,
  });

  factory ChatMessage.toolResult({
    required String toolCallId,
    required String name,
    required String content,
  }) {
    return ChatMessage(
      role: ChatRole.tool,
      content: content,
      toolCallId: toolCallId,
      name: name,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'role': switch (role) {
        ChatRole.system => 'system',
        ChatRole.user => 'user',
        ChatRole.assistant => 'assistant',
        ChatRole.tool => 'tool',
      },
      'content': content,
    };
    if (toolCallId != null) json['tool_call_id'] = toolCallId;
    if (name != null) json['name'] = name;
    if (toolCalls != null) json['tool_calls'] = toolCalls;
    return json;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: switch (json['role'] as String? ?? 'user') {
          'system' => ChatRole.system,
          'assistant' => ChatRole.assistant,
          'tool' => ChatRole.tool,
          _ => ChatRole.user,
        },
        content: (json['content'] as String?) ?? '',
        toolCallId: json['tool_call_id'] as String?,
        name: json['name'] as String?,
        reasoning: json['reasoning_content'] as String?,
      );
}

/// LLM 调用异常
class LlmException implements Exception {
  final String message;
  const LlmException(this.message);

  @override
  String toString() => message;
}

/// 流式返回的单个片段
///
/// [deltaText] 为本次新增的文本；[finalMessage] 为完整 assistant message
/// （含 tool_calls），仅在流结束时出现一次。
class LlmStreamChunk {
  final String? deltaText;

  /// 本次新增的思考过程（reasoning_content）
  final String? reasoningText;
  final Map<String, dynamic>? finalMessage;

  const LlmStreamChunk.delta(this.deltaText)
      : finalMessage = null,
        reasoningText = null;

  const LlmStreamChunk.reasoning(this.reasoningText)
      : finalMessage = null,
        deltaText = null;

  const LlmStreamChunk.done(this.finalMessage)
      : deltaText = null,
        reasoningText = null;
}

/// LLM 服务
///
/// 对接用户自备的大模型（OpenAI 兼容协议 /chat/completions）。
/// 用户在偏好设置中填写 API Base、API Key、Model 后即可使用。
/// 不内置任何密钥，所有凭据仅存于本地 SharedPreferences。
class LlmService {
  LlmService._();

  static final LlmService instance = LlmService._();

  /// 单次请求超时
  static const _timeout = Duration(seconds: 90);

  /// 调用聊天补全接口，返回助手回复文本。
  Future<String> chat({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.7,
  }) async {
    final message = await chatMessage(
      apiBase: apiBase,
      apiKey: apiKey,
      model: model,
      messages: messages,
      temperature: temperature,
    );
    final content = message['content'] as String?;
    if (content == null || content.trim().isEmpty) {
      throw const LlmException('LLM 未返回内容');
    }
    return content;
  }

  /// 调用聊天补全接口，返回原始 assistant message（支持 tool_calls）。
  ///
  /// [tools] 为 OpenAI function-calling 工具定义列表；为空时按普通对话处理。
  Future<Map<String, dynamic>> chatMessage({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double temperature = 0.7,
  }) async {
    if (apiBase.isEmpty || apiKey.isEmpty || model.isEmpty) {
      throw const LlmException('未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型');
    }

    final base = apiBase.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');

    final body = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
    };
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = toolChoice ?? 'auto';
    }

    final http.Response res;
    try {
      res = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      throw LlmException('网络请求失败：$e');
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      String detail = '';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final err = data['error'];
        if (err is Map) {
          detail = (err['message'] ?? err['code'] ?? '').toString();
        } else {
          detail = err?.toString() ?? res.body;
        }
      } catch (_) {
        detail = res.body.length > 300 ? res.body.substring(0, 300) : res.body;
      }
      throw LlmException(
        'LLM 调用失败（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}',
      );
    }

    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw const LlmException('LLM 返回为空');
      }
      final first = choices.first as Map<String, dynamic>;
      final message = first['message'] as Map<String, dynamic>?;
      if (message == null) {
        throw const LlmException('LLM 返回格式异常');
      }
      return message;
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('解析 LLM 响应失败：$e');
    }
  }

  /// 流式调用聊天补全接口（SSE），逐段返回文本，最后返回完整 message。
  ///
  /// 若服务端不支持流式（直接返回 JSON），会自动按非流式解析。
  Stream<LlmStreamChunk> streamChatMessage({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double temperature = 0.7,
  }) async* {
    if (apiBase.isEmpty || apiKey.isEmpty || model.isEmpty) {
      throw const LlmException('未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型');
    }

    final base = apiBase.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final body = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
      'stream': true,
    };
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = toolChoice ?? 'auto';
    }

    final client = http.Client();
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
          'Authorization': 'Bearer $apiKey',
        })
        ..body = jsonEncode(body);

      final res = await client.send(request).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final text = await res.stream.bytesToString();
        final detail = text.length > 300 ? text.substring(0, 300) : text;
        throw LlmException('LLM 调用失败（HTTP ${res.statusCode}）：$detail');
      }

      final content = StringBuffer();
      final reasoning = StringBuffer();
      final toolCalls = <int, Map<String, dynamic>>{};
      final nonSse = StringBuffer();

      await for (final line
          in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) {
          if (nonSse.length < 200 * 1024) nonSse.writeln(line);
          continue;
        }
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;

        Map<String, dynamic> json;
        try {
          json = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is! Map) continue;

        final text = delta['content'];
        if (text is String && text.isNotEmpty) {
          content.write(text);
          yield LlmStreamChunk.delta(text);
        }

        final reasoningText = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoningText is String && reasoningText.isNotEmpty) {
          reasoning.write(reasoningText);
          yield LlmStreamChunk.reasoning(reasoningText);
        }

        final calls = delta['tool_calls'];
        if (calls is List) {
          for (final raw in calls) {
            if (raw is! Map) continue;
            final index = (raw['index'] as num?)?.toInt() ?? toolCalls.length;
            final entry = toolCalls.putIfAbsent(
              index,
              () => {
                'id': '',
                'type': 'function',
                'function': {'name': '', 'arguments': ''},
              },
            );
            final id = raw['id'];
            if (id is String && id.isNotEmpty) entry['id'] = id;
            final fn = raw['function'];
            if (fn is Map) {
              final name = fn['name'];
              if (name is String && name.isNotEmpty) {
                (entry['function'] as Map)['name'] = name;
              }
              final args = fn['arguments'];
              if (args is String) {
                final current =
                    (entry['function'] as Map)['arguments'] as String;
                (entry['function'] as Map)['arguments'] = current + args;
              }
            }
          }
        }
      }

      // 服务端直接返回 JSON（非 SSE）时按普通响应解析
      if (content.isEmpty && toolCalls.isEmpty && nonSse.isNotEmpty) {
        try {
          final data = jsonDecode(nonSse.toString()) as Map<String, dynamic>;
          final choices = data['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final message =
                (choices.first as Map)['message'] as Map<String, dynamic>?;
            if (message != null) {
              final text = message['content'];
              if (text is String && text.isNotEmpty) {
                yield LlmStreamChunk.delta(text);
              }
              final think = message['reasoning_content'] ?? message['reasoning'];
              if (think is String && think.isNotEmpty) {
                yield LlmStreamChunk.reasoning(think);
              }
              yield LlmStreamChunk.done(message);
              return;
            }
          }
        } catch (_) {
          // 忽略，按空结果返回
        }
      }

      final message = <String, dynamic>{
        'role': 'assistant',
        'content': content.toString(),
      };
      if (reasoning.isNotEmpty) {
        message['reasoning_content'] = reasoning.toString();
      }
      if (toolCalls.isNotEmpty) {
        final keys = toolCalls.keys.toList()..sort();
        message['tool_calls'] = keys.map((key) => toolCalls[key]).toList();
      }
      yield LlmStreamChunk.done(message);
    } catch (e) {
      if (e is LlmException) rethrow;
      throw LlmException('流式请求失败：$e');
    } finally {
      client.close();
    }
  }

  /// 从助手回复中提取代码块。
  ///
  /// 支持 ```lang ... ``` 围栏代码块；若无围栏则返回原文。
  static String extractCode(String content) {
    final fence = RegExp(r'```[\w-]*\n([\s\S]*?)```', multiLine: true);
    final match = fence.firstMatch(content);
    if (match != null) return match.group(1)!.trim();
    return content.trim();
  }

  /// 从助手回复中提取指定语言的代码块。
  static String? extractCodeByLang(String content, String lang) {
    final fence = RegExp(
      '```${RegExp.escape(lang)}\\n([\\s\\S]*?)```',
      multiLine: true,
    );
    final match = fence.firstMatch(content);
    if (match != null) return match.group(1)!.trim();
    return null;
  }
}
