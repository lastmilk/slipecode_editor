import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../agent/mcp_tools.dart';
import '../models/app_settings.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/llm_service.dart';

/// AI 助手状态
enum AiStatus { idle, thinking, error }

/// AI 助手 Provider
///
/// 基于 Skill.md + MCP 工具集运行的 Agent：
/// 1. 读取项目文件、搜索代码、创建/修改/删除文件
/// 2. 触发云端构建
/// 3. 多轮「调用工具 → 观察结果 → 继续」循环
class AiProvider extends ChangeNotifier {
  AiProvider(this._settings, this._editor, BuildProvider build, this._project)
      : _toolbox = McpToolbox(
          project: _project,
          editor: _editor,
          build: build,
        ) {
    _agent = AgentService(_project, _toolbox);
  }

  final SettingsProvider _settings;
  final EditorProvider _editor;
  final ProjectProvider _project;

  final McpToolbox _toolbox;
  late final AgentService _agent;

  final List<ChatMessage> _messages = [];
  final List<AgentToolStep> _steps = [];
  AiStatus _status = AiStatus.idle;
  String? _error;
  bool _disposed = false;

  /// 对话历史（只读）
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// 本轮 Agent 已执行的工具调用
  List<AgentToolStep> get steps => List.unmodifiable(_steps);

  AiStatus get status => _status;
  String? get error => _error;
  bool get isThinking => _status == AiStatus.thinking;

  /// 是否已配置 LLM
  bool get isConfigured => _settings.settings.isLlmConfigured;

  AppSettings get _s => _settings.settings;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// 清空对话
  void clear() {
    _messages.clear();
    _steps.clear();
    _error = null;
    _status = AiStatus.idle;
    _safeNotify();
  }

  /// 发送一条用户消息，Agent 会自动调用工具完成任务
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (!isConfigured) {
      _error = '未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    _messages.add(ChatMessage(role: ChatRole.user, content: text));
    _steps.clear();
    _status = AiStatus.thinking;
    _error = null;
    _safeNotify();

    // 只带最近 20 条，避免 token 爆炸
    final history = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;

    try {
      final result = await _agent.run(
        apiBase: _s.llmApiBase,
        apiKey: _s.llmApiKey,
        model: _s.llmModel,
        history: List<ChatMessage>.from(history),
        onStep: (step) {
          _steps.add(step);
          _safeNotify();
        },
      );
      _messages.add(
        ChatMessage(role: ChatRole.assistant, content: result.content),
      );
      _status = AiStatus.idle;
    } catch (e) {
      _error = '$e';
      _status = AiStatus.error;
    }
    _safeNotify();
  }

  /// 把当前活动文件的内容附加到消息中发送
  Future<void> sendWithCurrentFile(String instruction) async {
    final active = _editor.activeFile;
    if (active == null) {
      _error = '当前没有打开的文件';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }
    final fileName = active.path.split(RegExp(r'[/\\]')).last;
    final lang = _project.payload.languageFor(active.path);
    final text =
        '$instruction\n\n当前文件：`$fileName`\n\n```$lang\n${active.content}\n```';
    await sendMessage(text);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
