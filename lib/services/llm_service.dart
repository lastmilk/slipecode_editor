import 'dart:convert';

import 'package:http/http.dart' as http;

/// 聊天消息角色
enum ChatRole { system, user, assistant }

/// 单条聊天消息
class ChatMessage {
  final ChatRole role;
  final String content;

  const ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {
        'role': switch (role) {
          ChatRole.system => 'system',
          ChatRole.user => 'user',
          ChatRole.assistant => 'assistant',
        },
        'content': content,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: switch (json['role'] as String? ?? 'user') {
          'system' => ChatRole.system,
          'assistant' => ChatRole.assistant,
          _ => ChatRole.user,
        },
        content: (json['content'] as String?) ?? '',
      );
}

/// LLM 调用异常
class LlmException implements Exception {
  final String message;
  const LlmException(this.message);

  @override
  String toString() => message;
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
  static const _timeout = Duration(seconds: 60);

  /// 调用聊天补全接口，返回助手回复文本。
  ///
  /// [apiBase] 形如 https://api.openai.com/v1
  /// [apiKey]  用户的 API Key
  /// [model]   模型名称
  /// [messages] 对话历史（含 system / user / assistant）
  Future<String> chat({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.7,
  }) async {
    if (apiBase.isEmpty || apiKey.isEmpty || model.isEmpty) {
      throw const LlmException('未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型');
    }

    final base = apiBase.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');

    final body = {
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
    };

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
      throw LlmException('LLM 调用失败（HTTP ${res.statusCode}）${detail.isEmpty ? '' : '：$detail'}');
    }

    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw const LlmException('LLM 返回为空');
      }
      final first = choices.first as Map<String, dynamic>;
      final message = first['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const LlmException('LLM 未返回内容');
      }
      return content;
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('解析 LLM 响应失败：$e');
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
    final fence = RegExp('```${RegExp.escape(lang)}\\n([\\s\\S]*?)```', multiLine: true);
    final match = fence.firstMatch(content);
    if (match != null) return match.group(1)!.trim();
    return null;
  }
}
