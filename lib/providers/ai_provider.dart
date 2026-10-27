import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/llm_service.dart';
import 'build_provider.dart';
import 'editor_provider.dart';
import 'settings_provider.dart';

/// AI 助手状态
enum AiStatus { idle, thinking, error }

/// AI 助手 Provider
///
/// 管理与大模型的对话，支持：
/// 1. 代码编辑 —— 把当前文件内容发给 AI，应用返回的代码
/// 2. 触发构建 —— 调用 BuildProvider 启动 GitHub Actions 云端构建
class AiProvider extends ChangeNotifier {
  AiProvider(this._settings, this._editor, this._build);

  final SettingsProvider _settings;
  final EditorProvider _editor;
  final BuildProvider _build;

  final List<ChatMessage> _messages = [];
  AiStatus _status = AiStatus.idle;
  String? _error;
  bool _disposed = false;

  /// 对话历史（只读）
  List<ChatMessage> get messages => List.unmodifiable(_messages);

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
    _error = null;
    _safeNotify();
  }

  /// 构建系统提示词：告诉 AI 它的能力与输出规范
  String _systemPrompt() {
    return '''你是 SlipCode 代码编辑器内置的 AI 助手，运行在 Android 手机上，帮助用户编写 Flutter/Dart 项目。

你的能力：
1. 代码编辑：用户会把当前打开的文件内容发给你。请直接返回修改后的完整文件内容，用 ```dart 代码块包裹（若是其他语言则用对应语言标记）。不要只返回片段，要返回整个文件。
2. 代码解释：回答用户关于代码的问题，简洁清晰。
3. 触发构建：当用户要求"构建"、"打包"、"build"时，回复会触发云端 GitHub Actions 构建（APK）。

输出规范：
- 修改代码时，必须用 ```语言名 ... ``` 包裹完整文件内容。
- 非代码内容用自然语言说明。
- 不要编造不存在的 API。''';
  }

  /// 发送一条用户消息并获取 AI 回复
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (!isConfigured) {
      _error = '未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    _messages.add(ChatMessage(role: ChatRole.user, content: text));
    _status = AiStatus.thinking;
    _error = null;
    _safeNotify();

    // 构造请求消息：system + 历史（最近 20 条，避免 token 爆炸）
    final history = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;
    final requestMessages = <ChatMessage>[
      ChatMessage(role: ChatRole.system, content: _systemPrompt()),
      ...history,
    ];

    try {
      final reply = await LlmService.instance.chat(
        apiBase: _s.llmApiBase,
        apiKey: _s.llmApiKey,
        model: _s.llmModel,
        messages: requestMessages,
      );
      _messages.add(ChatMessage(role: ChatRole.assistant, content: reply));
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
    final lang = _detectLang(active.path);
    final text =
        '$instruction\n\n当前文件：`$fileName`\n\n```$lang\n${active.content}\n```';
    await sendMessage(text);
  }

  /// 把 AI 最近一条回复中的代码应用到当前活动文件
  ///
  /// 返回是否成功应用。
  bool applyLatestCodeToActiveFile() {
    if (!_editor.hasActiveFile) return false;
    final lastAssistant = _messages.reversed
        .where((m) => m.role == ChatRole.assistant)
        .firstOrNull;
    if (lastAssistant == null) return false;

    final lang = _detectLang(_editor.activeFile!.path);
    var code = LlmService.extractCodeByLang(lastAssistant.content, lang);
    code ??= LlmService.extractCode(lastAssistant.content);
    if (code.isEmpty) return false;

    _editor.updateActiveContent(code);
    return true;
  }

  /// 触发云端构建（GitHub Actions）
  Future<String> triggerBuild() async {
    if (_build.isRunning) return '构建已在进行中';
    // build 需要项目目录，由调用方（UI）传入；这里返回状态提示
    return 'build';
  }

  String _detectLang(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.dart')) return 'dart';
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'yaml';
    if (lower.endsWith('.json')) return 'json';
    if (lower.endsWith('.xml')) return 'xml';
    if (lower.endsWith('.kt') || lower.endsWith('.java')) return 'kotlin';
    if (lower.endsWith('.md')) return 'markdown';
    return 'text';
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
