import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../agent/mcp_tools.dart';
import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/chat_segment.dart';
import '../models/credits.dart';
import '../models/llm_profile.dart';
import '../providers/account_provider.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/ai_extensions_service.dart';
import '../services/conversation_service.dart';
import '../services/external_mcp_manager.dart';
import '../services/llm_service.dart';

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

  /// 当前流式回复的渲染分段（思考过程 / 工具调用批次 / 正文按时间穿插）
  final List<ChatSegment> _streamSegments = [];

  /// 计划模式（/plan 指令开启）：AI 只制定计划，用户确认后再执行
  bool _planMode = false;

  // 对话记录
  bool _historyLoaded = false;

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

  /// 当前流式回复的渲染分段（思考 / 工具批次 / 正文按时间穿插）
  List<ChatSegment> get streamSegments => List.unmodifiable(_streamSegments);

  /// 是否为计划模式（/plan）：AI 只制定计划，不执行写操作
  bool get planMode => _planMode;

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

  /// 重新加载第三方 MCP 工具（新增 / 编辑 / 启用服务器后调用）
  Future<void> refreshMcpTools() async {
    await _prepareExtensions();
    _safeNotify();
  }

  /// 清空当前会话消息（会话本身保留在列表中）
  Future<void> clear() async {
    _messages.clear();
    _steps.clear();
    _timeline.clear();
    _streamSegments.clear();
    _error = null;
    _status = AiStatus.idle;
    _streamingText = '';
    _streamingReasoning = '';
    _isStreaming = false;
    final currentId = ConversationService.instance.currentId;
    if (currentId != null) {
      ConversationService.instance.updateMessages(currentId, const []);
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // 多会话管理（DeepSeek 风格侧边栏，支持跨端同步）
  // ---------------------------------------------------------------------------

  /// 会话列表服务（供侧边栏直接监听 / 操作）
  ConversationService get conversations => ConversationService.instance;

  /// 加载会话列表（按当前登录用户隔离；开启云同步时自动与云端合并）
  Future<void> ensureSessionsLoaded() async {
    await ConversationService.instance.ensureLoaded(
      userId: _account.user?.id ?? '',
      token: _account.token,
      cloudEnabled: _s.chatCloudSync && _account.isSignedIn,
      settings: _s,
    );
  }

  /// 打开 Agent 面板时加载会话与当前会话消息
  Future<void> ensureCloudHistoryLoaded() async {
    await ensureSessionsLoaded();
    if (_historyLoaded) return;
    _historyLoaded = true;
    final current = ConversationService.instance.current;
    if (current != null && current.messages.isNotEmpty) {
      _messages.addAll(current.messages);
      _timeline.addAll(current.messages);
      _safeNotify();
    }
  }

  /// 新建会话并切换到它
  void startNewSession() {
    ConversationService.instance.createLocal();
    _loadCurrentSession();
  }

  /// 打开指定会话
  void openSession(String id) {
    if (ConversationService.instance.currentId == id) return;
    ConversationService.instance.open(id);
    _loadCurrentSession();
  }

  /// 删除会话；若删除的是当前会话则切换到最近的会话
  Future<void> deleteSession(String id) async {
    final service = ConversationService.instance;
    final wasCurrent = service.currentId == id;
    await service.delete(id);
    if (!wasCurrent) return;
    final next = service.conversations.firstOrNull;
    if (next != null) {
      service.open(next.id);
    }
    _loadCurrentSession();
  }

  /// 把当前会话消息加载进对话区
  void _loadCurrentSession() {
    _messages
      ..clear()
      ..addAll(ConversationService.instance.current?.messages ?? []);
    _steps.clear();
    _timeline
      ..clear()
      ..addAll(_messages);
    _streamSegments.clear();
    _error = null;
    _status = AiStatus.idle;
    _isStreaming = false;
    _streamingText = '';
    _streamingReasoning = '';
    _historyLoaded = true;
    _safeNotify();
  }

  /// 当前会话消息变化后持久化（本地 + 云端防抖同步）
  void _persistConversation() {
    final currentId = ConversationService.instance.currentId;
    if (currentId != null) {
      ConversationService.instance.updateMessages(currentId, _messages);
    }
  }

  // ---------------------------------------------------------------------------
  // 计划模式（/plan 指令）
  // ---------------------------------------------------------------------------

  /// 开启 / 关闭计划模式
  void setPlanMode(bool value) {
    if (_planMode == value) return;
    _planMode = value;
    _safeNotify();
  }

  /// 用户确认后，退出计划模式并按最近一条计划开始执行
  Future<void> executePlan() async {
    _planMode = false;
    await sendMessage('计划已确认，请严格按照上述计划开始执行。');
  }

  /// 发送一条用户消息，Agent 会自动调用工具完成任务（流式输出）
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    await ensureCloudHistoryLoaded();
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

    // 确保有当前会话（首条消息自动生成会话标题）
    ConversationService.instance.ensureCurrent(firstUserText: text);

    final userMessage = ChatMessage(role: ChatRole.user, content: text);
    _messages.add(userMessage);
    _timeline.add(userMessage);
    _steps.clear();
    _status = AiStatus.thinking;
    _error = null;
    _isStreaming = true;
    _streamingText = '';
    _streamingReasoning = '';
    _streamSegments.clear();
    _safeNotify();

    // 只带最近 20 条，避免 token 爆炸
    final history = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;

    _lastStreamNotify = DateTime.now();
    void onDelta(String delta) {
      _streamingText += delta;
      // 分段渲染：正文追加到末尾 text 段（否则新建一段）
      if (_streamSegments.isEmpty || !_streamSegments.last.isText) {
        _streamSegments.add(ChatSegment.text());
      }
      _streamSegments.last.text += delta;
      final now = DateTime.now();
      if (now.difference(_lastStreamNotify).inMilliseconds > 80) {
        _lastStreamNotify = now;
        _safeNotify();
      }
    }

    void onReasoning(String delta) {
      _streamingReasoning += delta;
      // 分段渲染：思考过程追加到末尾 reasoning 段（否则新建一段）
      if (_streamSegments.isEmpty || !_streamSegments.last.isReasoning) {
        _streamSegments.add(ChatSegment.reasoning());
      }
      _streamSegments.last.text += delta;
      final now = DateTime.now();
      if (now.difference(_lastStreamNotify).inMilliseconds > 80) {
        _lastStreamNotify = now;
        _safeNotify();
      }
    }

    final planOnly = _planMode;

    try {
      final result = await _agent.run(
        apiBase: llm.apiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        history: List<ChatMessage>.from(history),
        onStep: (step) {
          if (!_steps.contains(step)) _steps.add(step);
          if (!_timeline.contains(step)) _timeline.add(step);
          // 分段渲染：连续的工具调用聚合为一个批次段
          if (_streamSegments.isEmpty || !_streamSegments.last.isTools) {
            _streamSegments.add(ChatSegment.tools([]));
          }
          final batch = _streamSegments.last;
          if (!batch.steps.contains(step)) batch.steps.add(step);
          _safeNotify();
        },
        onDelta: onDelta,
        onReasoning: onReasoning,
        extraSystemPrompt: extraSkill,
        planOnly: planOnly,
      );
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      final reply = ChatMessage(
        role: ChatRole.assistant,
        content: result.content,
        reasoning: result.reasoning.isEmpty ? null : result.reasoning,
        kind: planOnly ? 'plan' : 'normal',
        segments: _streamSegments.isEmpty
            ? null
            : List<ChatSegment>.from(_streamSegments),
      );
      _messages.add(reply);
      _timeline.add(reply);
      _status = AiStatus.idle;
      // 计划产出后自动退出计划模式，等待用户确认执行
      if (planOnly) _planMode = false;
    } catch (e) {
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      _error = '$e';
      _status = AiStatus.error;
    }
    _streamSegments.clear();
    _safeNotify();
    if (llm.builtin) {
      // 内置模型按 token 扣积分，调用结束后刷新余额
      await _account.refreshCredits();
    }
    _persistConversation();
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
    super.dispose();
  }
}
