import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../agent/mcp_tools.dart';
import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/credits.dart';
import '../models/llm_profile.dart';
import '../providers/account_provider.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/account_service.dart';
import '../services/ai_extensions_service.dart';
import '../services/chat_history_service.dart';
import '../services/external_mcp_manager.dart';
import '../services/llm_service.dart';
import '../services/network_policy.dart';

/// AI 助手状态
enum AiStatus { idle, thinking, error }

/// 当前实际生效的模型（内置模型或用户自定义模型）
class _ResolvedLlm {
  final String apiBase;
  final String apiKey;
  final String model;
  final String name;
  final bool builtin;

  const _ResolvedLlm({
    required this.apiBase,
    required this.apiKey,
    required this.model,
    required this.name,
    required this.builtin,
  });
}

/// AI 助手 Provider
///
/// 基于 Skill.md + MCP 工具集运行的 Agent：
/// 1. 流式输出（边生成边展示）
/// 2. 读取项目文件、搜索代码、创建/修改/删除文件
/// 3. 触发云端构建
/// 4. 多轮「调用工具 → 观察结果 → 继续」循环
/// 5. 对话记录本地保存（可选上传云端）
class AiProvider extends ChangeNotifier {
  AiProvider(
    this._settings,
    this._editor,
    BuildProvider build,
    this._project,
    this._account, {
    TerminalProvider? terminal,
  }) {
    _toolbox = McpToolbox(
      project: _project,
      editor: _editor,
      build: build,
      // 仅桌面端（本地 shell 可用）时向 Agent 暴露终端工具
      terminal: terminal,
    );
    _agent = AgentService(_project, _toolbox);
  }

  final SettingsProvider _settings;
  final EditorProvider _editor;
  final ProjectProvider _project;
  final AccountProvider _account;

  late final McpToolbox _toolbox;
  late final AgentService _agent;

  final List<ChatMessage> _messages = [];
  final List<AgentToolStep> _steps = [];

  /// 对话时间线：按真实顺序排列的「消息 / 工具调用卡片」
  final List<Object> _timeline = [];
  AiStatus _status = AiStatus.idle;
  String? _error;
  bool _disposed = false;

  // 流式输出
  bool _isStreaming = false;
  String _streamingText = '';
  String _streamingReasoning = '';
  DateTime _lastStreamNotify = DateTime.now();

  // 对话记录
  bool _historyLoaded = false;
  bool _cloudHistoryPulled = false;
  Timer? _pushTimer;

  // VibeCoding
  bool _vibeBusy = false;
  bool _vibeCancelled = false;
  String _vibeThinking = '';

  /// 对话历史（只读）
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// 本轮 Agent 已执行的工具调用
  List<AgentToolStep> get steps => List.unmodifiable(_steps);

  /// 对话时间线（ChatMessage 与 AgentToolStep 混排）
  ///
  /// 工具调用及其结果会显式穿插在对话流中，而不是只显示在底部面板。
  List<Object> get timeline => List.unmodifiable(_timeline);

  AiStatus get status => _status;
  String? get error => _error;
  bool get isThinking => _status == AiStatus.thinking;

  /// 是否正在流式接收
  bool get isStreaming => _isStreaming;

  /// 当前流式接收中的文本
  String get streamingText => _streamingText;

  /// 当前流式接收中的思考过程（DeepSeek / StepFun 等推理模型）
  String get streamingReasoning => _streamingReasoning;

  /// VibeCoding 是否正在执行（编辑器需锁定）
  bool get vibeBusy => _vibeBusy;

  /// VibeCoding 期间的模型输出（Agent 面板展示「思考过程」）
  String get vibeThinking => _vibeThinking;

  /// 是否可用（内置模型需登录；自定义模型需完整配置）
  bool get isConfigured => _resolveLlm() != null;

  /// 当前模型展示名称
  String get currentModelName => _resolveLlm()?.name ?? '未选择模型';

  /// 当前是否使用内置模型
  bool get isUsingBuiltinModel => _resolveLlm()?.builtin ?? false;

  /// Agent 可调用的 MCP 工具（用于 AGC 模式「MCP/Skills」面板展示）
  List<McpTool> get mcpTools => List.unmodifiable(_toolbox.tools);

  AppSettings get _s => _settings.settings;

  /// 解析当前实际生效的模型
  ///
  /// 优先使用 SLIPE 内置模型（登录后）；不可用时回退到用户自定义模型。
  _ResolvedLlm? _resolveLlm() {
    final s = _s;
    if (s.llmUseBuiltin) {
      final base = AppConfig.accountBackendBase;
      final token = _account.token;
      if (_account.isSignedIn && token != null && base.isNotEmpty) {
        final models = _account.builtinModels;
        if (models.isNotEmpty) {
          final wanted = s.builtinLlmId.isNotEmpty
              ? s.builtinLlmId
              : _account.defaultBuiltinModelId;
          final selected = models.where((m) => m.id == wanted).firstOrNull ??
              models.first;
          return _ResolvedLlm(
            apiBase: '$base/api/llm',
            apiKey: token,
            model: selected.id,
            name: selected.name,
            builtin: true,
          );
        }
      }
    }
    final llm = s.activeLlm;
    if (llm != null && llm.isConfigured) {
      return _ResolvedLlm(
        apiBase: llm.normalizedApiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        name: llm.name,
        builtin: false,
      );
    }
    return null;
  }

  /// 为内置模型选择/刷新模型列表（供 UI 调用）
  Future<void> ensureBuiltinModels() async {
    if (!_settings.settings.llmUseBuiltin || !_account.isSignedIn) return;
    if (_account.builtinModels.isEmpty) {
      await _account.refreshBuiltinModels();
    }
  }

  /// 用户切换模型
  Future<void> selectBuiltinModel(BuiltinLlmModel model) async {
    await _settings.setBuiltinLlm(model.id);
    _safeNotify();
  }

  Future<void> selectCustomModel(LlmProfile profile) async {
    await _settings.setActiveLlm(profile.id);
    _safeNotify();
  }

  /// 加载用户配置的第三方 MCP 与外源 Skill
  Future<String> _prepareExtensions() async {
    final extensions = AiExtensionsService.instance;
    await extensions.ensureLoaded();
    try {
      _toolbox.externalManager = ExternalMcpManager.instance;
      await ExternalMcpManager.instance.configure(extensions.enabledServers);
    } catch (e) {
      debugPrint('第三方 MCP 初始化失败：$e');
    }
    return extensions.enabledSkillsText;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// 清空对话（同时清空本地与已开启的云端记录）
  Future<void> clear() async {
    _messages.clear();
    _steps.clear();
    _timeline.clear();
    _error = null;
    _status = AiStatus.idle;
    _streamingText = '';
    _isStreaming = false;
    await ChatHistoryService.instance.clear();
    if (_s.chatCloudSync && _account.isSignedIn) {
      try {
        await AccountService.instance.deleteChatHistory(_account.token!);
      } catch (_) {
        // 云端清空失败不影响本地
      }
    }
    _safeNotify();
  }

  /// 首次打开 Agent 面板时加载本地记录；开启云同步时拉取云端补充
  Future<void> ensureCloudHistoryLoaded() async {
    await _ensureHistoryLoaded();
    if (_cloudHistoryPulled) return;
    _cloudHistoryPulled = true;
    if (!_s.chatCloudSync || !_account.isSignedIn) return;
    try {
      if (!await NetworkPolicy.canSyncNow(_s)) return;
      final remote =
          await AccountService.instance.fetchChatHistory(_account.token!);
      if (remote.isEmpty) return;
      final existing = _messages
          .map((m) => '${m.role.name}|${m.content}')
          .toSet();
      for (final item in remote) {
        final role =
            item['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user;
        final content = (item['content'] ?? '').toString();
        if (content.isEmpty || existing.contains('${role.name}|$content')) {
          continue;
        }
        final message = ChatMessage(role: role, content: content);
        _messages.add(message);
        _timeline.add(message);
      }
      _safeNotify();
    } catch (e) {
      debugPrint('拉取云端对话记录失败：$e');
    }
  }

  Future<void> _ensureHistoryLoaded() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    try {
      final records = await ChatHistoryService.instance.load();
      for (final item in records) {
        final content = (item['content'] ?? '').toString();
        if (content.isEmpty) continue;
        final reasoning = (item['reasoning'] ?? '').toString();
        final message = ChatMessage(
          role: item['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user,
          content: content,
          reasoning: reasoning.isEmpty ? null : reasoning,
        );
        _messages.add(message);
        _timeline.add(message);
      }
      if (_messages.isNotEmpty) _safeNotify();
    } catch (e) {
      debugPrint('读取本地对话记录失败：$e');
    }
  }

  Future<void> _persistHistory() async {
    final records = <Map<String, dynamic>>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final message in _messages) {
      if (message.role != ChatRole.user &&
          message.role != ChatRole.assistant) {
        continue;
      }
      records.add({
        'role': message.role == ChatRole.assistant ? 'assistant' : 'user',
        'content': message.content,
        if (message.reasoning != null && message.reasoning!.isNotEmpty)
          'reasoning': message.reasoning,
        'ts': now,
      });
    }
    await ChatHistoryService.instance.save(records);

    if (!_s.chatCloudSync || !_account.isSignedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 2), () async {
      try {
        if (!await NetworkPolicy.canSyncNow(_s)) return;
        await AccountService.instance.pushChatHistory(
          _account.token!,
          records,
        );
      } catch (e) {
        debugPrint('上传对话记录失败：$e');
      }
    });
  }

  /// 发送一条用户消息，Agent 会自动调用工具完成任务（流式输出）
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    await _ensureHistoryLoaded();
    // 合规：未同意《用户协议》与《隐私政策》→ 受限模式，AI 助手不可用
    if (_settings.settings.policyAcceptedVersion.isEmpty) {
      _error = t('ai.error.policyFirst');
      _status = AiStatus.error;
      _safeNotify();
      return;
    }
    // 首次使用内置模型时先拉取模型列表（默认 DeepSeek Flash）
    await ensureBuiltinModels();
    final llm = _resolveLlm();
    if (llm == null) {
      _error = t('ai.error.llmNotConfigured');
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    final extraSkill = await _prepareExtensions();

    final userMessage = ChatMessage(role: ChatRole.user, content: text);
    _messages.add(userMessage);
    _timeline.add(userMessage);
    _steps.clear();
    _status = AiStatus.thinking;
    _error = null;
    _isStreaming = true;
    _streamingText = '';
    _streamingReasoning = '';
    _safeNotify();

    // 只带最近 20 条，避免 token 爆炸
    final history = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;

    _lastStreamNotify = DateTime.now();
    void onDelta(String delta) {
      _streamingText += delta;
      final now = DateTime.now();
      if (now.difference(_lastStreamNotify).inMilliseconds > 80) {
        _lastStreamNotify = now;
        _safeNotify();
      }
    }

    void onReasoning(String delta) {
      _streamingReasoning += delta;
      final now = DateTime.now();
      if (now.difference(_lastStreamNotify).inMilliseconds > 80) {
        _lastStreamNotify = now;
        _safeNotify();
      }
    }

    try {
      final result = await _agent.run(
        apiBase: llm.apiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        history: List<ChatMessage>.from(history),
        onStep: (step) {
          if (!_steps.contains(step)) _steps.add(step);
          if (!_timeline.contains(step)) _timeline.add(step);
          _safeNotify();
        },
        onDelta: onDelta,
        onReasoning: onReasoning,
        extraSystemPrompt: extraSkill,
      );
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      final reply = ChatMessage(
        role: ChatRole.assistant,
        content: result.content,
        reasoning: result.reasoning.isEmpty ? null : result.reasoning,
      );
      _messages.add(reply);
      _timeline.add(reply);
      _status = AiStatus.idle;
    } catch (e) {
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      _error = '$e';
      _status = AiStatus.error;
    }
    _safeNotify();
    if (llm.builtin) {
      // 内置模型按 token 扣积分，调用结束后刷新余额
      await _account.refreshCredits();
    }
    await _persistHistory();
  }

  /// 把当前文件的内容附加到消息中发送
  Future<void> sendWithCurrentFile(String instruction) async {
    final active = _editor.activeFile;
    if (active == null) {
      _error = t('ai.error.noFileOpen');
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

  // ---------------------------------------------------------------------------
  // VibeCoding
  // ---------------------------------------------------------------------------

  /// 执行一次 VibeCoding：删除触发词所在行，交由 Agent 直接改文件
  ///
  /// 期间 [vibeBusy] 为 true，编辑器应切换为只读。
  Future<void> runVibeCoding({
    required String filePath,
    required String requirement,
    required int lineStart,
    required int lineEnd,
  }) async {
    if (_vibeBusy) return;
    await ensureBuiltinModels();
    final llm = _resolveLlm();
    if (llm == null) {
      _error = t('ai.error.llmNotConfiguredVibe');
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    final extraSkill = await _prepareExtensions();

    _vibeBusy = true;
    _vibeCancelled = false;
    _vibeThinking = '';
    _steps.clear();
    _error = null;
    _status = AiStatus.thinking;
    _safeNotify();

    try {
      // 1) 移除触发词所在行并落盘，保证磁盘与编辑器一致
      final text = _editor.activeFile?.content ?? '';
      final lineNumber =
          '\n'.allMatches(text.substring(0, lineStart.clamp(0, text.length)))
                  .length +
              1;
      await _editor.replaceRangeAndSave(filePath, lineStart, lineEnd, '');

      // 2) 交给 Agent 用工具实现需求
      final result = await _agent.run(
        apiBase: llm.apiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        history: [
          ChatMessage(
            role: ChatRole.user,
            content: '在项目文件 `$filePath` 的第 $lineNumber 行附近实现以下需求：\n'
                '$requirement\n\n'
                '要求：直接使用工具修改文件，不要只在回复里贴代码；'
                '保持现有缩进与代码风格；完成后简要说明改了什么。',
          ),
        ],
        onStep: (step) {
          _steps.add(step);
          _safeNotify();
        },
        onDelta: (delta) {
          _vibeThinking += delta;
          _safeNotify();
        },
        onReasoning: (delta) {
          _vibeThinking += delta;
          _safeNotify();
        },
        extraSystemPrompt: extraSkill,
        isCancelled: () => _vibeCancelled,
      );

      await _editor.reloadFile(filePath);
      _status = AiStatus.idle;
      _vibeThinking = result.content;
    } catch (e) {
      _error = t('ai.error.vibeFailed', {'error': '$e'});
      _status = AiStatus.error;
    } finally {
      _vibeBusy = false;
      _safeNotify();
    }
    if (llm.builtin) {
      await _account.refreshCredits();
    }
  }

  /// 取消正在进行的 VibeCoding
  void cancelVibe() {
    if (!_vibeBusy) return;
    _vibeCancelled = true;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _pushTimer?.cancel();
    super.dispose();
  }
}
