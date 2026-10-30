import '../config/app_config.dart';
import '../models/llm_profile.dart';

/// 预置模型服务商
class LlmPreset {
  final String id;
  final String name;

  /// API 基础地址；SLIPE 云端在 [LlmPresets.apiBaseFor] 中动态解析
  final String apiBase;

  /// 候选模型
  final List<String> models;

  /// 是否依赖登录（SLIPE 云端模型）
  final bool requiresLogin;

  /// 一句话说明（设置页展示）
  final String note;

  const LlmPreset({
    required this.id,
    required this.name,
    required this.apiBase,
    required this.models,
    this.requiresLogin = false,
    this.note = '',
  });

  String get defaultModel => models.isEmpty ? '' : models.first;

  /// 用该预置生成一个配置
  LlmProfile toProfile({String apiKey = '', String? model}) => LlmProfile(
        id: LlmProfile.newId(),
        name: name,
        apiBase: LlmPresets.apiBaseFor(this),
        apiKey: apiKey,
        model: model ?? defaultModel,
        presetId: id,
        requiresLogin: requiresLogin,
      );
}

/// 内置预置清单
class LlmPresets {
  LlmPresets._();

  static const List<LlmPreset> list = [
    LlmPreset(
      id: 'openai',
      name: 'OpenAI',
      apiBase: 'https://api.openai.com/v1',
      models: ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
      note: '官方 OpenAI API',
    ),
    LlmPreset(
      id: 'deepseek',
      name: 'DeepSeek',
      apiBase: 'https://api.deepseek.com/v1',
      models: ['deepseek-chat', 'deepseek-reasoner'],
      note: '性价比高，支持工具调用',
    ),
    LlmPreset(
      id: 'dashscope',
      name: '阿里云百炼（通义）',
      apiBase: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      models: ['qwen-plus', 'qwen-max', 'qwen-turbo'],
      note: 'OpenAI 兼容模式',
    ),
    LlmPreset(
      id: 'moonshot',
      name: '月之暗面 Kimi',
      apiBase: 'https://api.moonshot.cn/v1',
      models: ['moonshot-v1-8k', 'moonshot-v1-32k'],
    ),
    LlmPreset(
      id: 'zhipu',
      name: '智谱 GLM',
      apiBase: 'https://open.bigmodel.cn/api/paas/v4',
      models: ['glm-4-flash', 'glm-4-plus'],
    ),
    LlmPreset(
      id: 'siliconflow',
      name: '硅基流动',
      apiBase: 'https://api.siliconflow.cn/v1',
      models: [
        'deepseek-ai/DeepSeek-V3',
        'Qwen/Qwen2.5-Coder-32B-Instruct',
      ],
    ),
    LlmPreset(
      id: 'ollama',
      name: '本地 Ollama',
      apiBase: 'http://127.0.0.1:11434/v1',
      models: ['qwen2.5-coder:7b', 'llama3.1:8b'],
      note: '无需 API Key，需本机运行 Ollama',
    ),
    LlmPreset(
      id: 'slipcloud',
      name: 'SLIPE 云端',
      apiBase: '',
      models: [],
      requiresLogin: true,
      note: '登录后使用账号积分调用，模型列表由云端下发',
    ),
    LlmPreset(
      id: 'custom',
      name: '自定义',
      apiBase: '',
      models: [],
      note: '任意 OpenAI 兼容服务',
    ),
  ];

  static LlmPreset? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final preset in list) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 解析实际 API 地址（SLIPE 云端依赖账号后端地址）
  static String apiBaseFor(LlmPreset preset) {
    if (preset.id == 'slipcloud') {
      final base = AppConfig.accountBackendBase;
      return base.isEmpty ? '' : '$base/api/llm';
    }
    return preset.apiBase;
  }
}
