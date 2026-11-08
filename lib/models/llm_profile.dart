import 'dart:math';

/// 单个 LLM 模型配置（Provider Profile）
///
/// 一个配置对应一个 OpenAI 兼容的 /chat/completions 服务端点 + Key + 模型。
/// 用户可配置多个（OpenAI、DeepSeek、通义、本地 Ollama 等）并随时切换。
class LlmProfile {
  /// 唯一标识，例如 `p_1712345678_ab12`
  final String id;

  /// 展示名称，例如 `DeepSeek`
  final String name;

  /// API 基础地址（不含末尾斜杠），例如 https://api.deepseek.com/v1
  final String apiBase;

  /// API Key（本地 Ollama 等可留空）
  final String apiKey;

  /// 模型名称，例如 deepseek-chat
  final String model;

  /// 来源预置（[LlmPresets] 的 id）；自定义时为空
  final String? presetId;

  /// 是否依赖账号登录（历史字段，内置模型已改为服务端下发）
  final bool requiresLogin;

  const LlmProfile({
    required this.id,
    required this.name,
    required this.apiBase,
    this.apiKey = '',
    required this.model,
    this.presetId,
    this.requiresLogin = false,
  });

  /// 是否配置完整（本地模型允许空 Key）
  bool get isConfigured => apiBase.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 规范化后的 API 地址（去掉末尾斜杠）
  String get normalizedApiBase =>
      apiBase.trim().replaceAll(RegExp(r'/+$'), '');

  LlmProfile copyWith({
    String? id,
    String? name,
    String? apiBase,
    String? apiKey,
    String? model,
    String? presetId,
    bool? requiresLogin,
  }) {
    return LlmProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      apiBase: apiBase ?? this.apiBase,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      presetId: presetId ?? this.presetId,
      requiresLogin: requiresLogin ?? this.requiresLogin,
    );
  }

  Map<String, dynamic> toJson({bool includeKey = true}) => {
        'id': id,
        'name': name,
        'apiBase': apiBase,
        'apiKey': includeKey ? apiKey : '',
        'model': model,
        if (presetId != null) 'presetId': presetId,
        'requiresLogin': requiresLogin,
      };

  factory LlmProfile.fromJson(Map<String, dynamic> json) => LlmProfile(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        apiBase: (json['apiBase'] ?? '').toString(),
        apiKey: (json['apiKey'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        presetId: json['presetId'] as String?,
        requiresLogin: json['requiresLogin'] as bool? ?? false,
      );

  /// 生成新的唯一 id
  static String newId() {
    final rand = Random().nextInt(0xFFFF);
    return 'p_${DateTime.now().millisecondsSinceEpoch}_'
        '${rand.toRadixString(16).padLeft(4, '0')}';
  }
}
