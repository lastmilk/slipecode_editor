import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../agent/design_tools.dart';
import '../agent/mcp_tools.dart';
import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/chat_segment.dart';
import '../models/credits.dart';
import '../models/design_draft.dart';
import '../models/llm_profile.dart';
import '../payloads/loader/loader_payload.dart';
import '../providers/account_provider.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/ai_extensions_service.dart';
import '../services/conversation_service.dart';
import '../services/design_draft_service.dart';
import '../services/external_mcp_manager.dart';
import '../services/live_task_service.dart';
import '../services/llm_service.dart';
import '../services/project_agent_settings_service.dart';
import '../services/web_search_service.dart';

/// AI 助手状态
enum AiStatus { idle, thinking, error }

/// 当前实际生效的模型（内置模型或用户自定义模型）
class _ResolvedLlm {
  final String apiBase;
  final String apiKey;
  final String model;
  final String name;
  final bool builtin;

  /// 是否支持图片理解（自定义模型默认允许，由上游自行判断）
  final bool supportsVision;

  const _ResolvedLlm({
    required this.apiBase,
    required this.apiKey,
    required this.model,
    required this.name,
    required this.builtin,
    this.supportsVision = true,
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
    _toolbox
      ..onAskUser = _askUser
      ..onSubmitPlan = _submitPlan
      ..onTodoUpdate = (todos) {
        _todos = List.unmodifiable(todos);
        _safeNotify();
      };
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

  /// /design：先创建并编排设计稿，再执行实现
  bool _designMode = false;
  DesignDraft? _designDraft;

  /// /search：本轮启用联网搜索工具
  bool _searchMode = false;

  /// /mcpadd：本轮允许 AI 自行添加 MCP / Skill
  bool _mcpAddMode = false;

  // 阶段 TODO / 用户提问 / 计划确认
  List<AgentTodoItem> _todos = const [];
  Map<String, dynamic>? _pendingQuestion;
  Completer<String>? _questionCompleter;
  Map<String, dynamic>? _pendingPlan;
  Completer<bool>? _planCompleter;
  bool _cancelRequested = false;
  String? _lastUserText;
  bool _planApprovedInRun = false;

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

  /// 是否为设计稿优先模式（/design）
  bool get designMode => _designMode;

  /// /design 创建的设计稿（供 UI 提示 / 跳转）
  DesignDraft? get designDraft => _designDraft;

  /// 是否启用联网搜索（/search）
  bool get searchMode => _searchMode;

  /// 当前是否允许 AI 自行添加 MCP/Skill（/mcpadd）
  bool get mcpAddMode => _mcpAddMode;

  /// 最近一次用户请求（用于经验标题）
  String? get lastUserRequest => _lastUserText;

  /// 当前任务的阶段 TODO
  List<AgentTodoItem> get todos => _todos;

  /// 等待用户回答的问题
  Map<String, dynamic>? get pendingQuestion => _pendingQuestion;

  /// 等待用户确认的计划
  Map<String, dynamic>? get pendingPlan => _pendingPlan;

  /// 是否可以在失败 / 中断后重试
  bool get canRetry =>
      _error != null && _lastUserText != null && !isThinking;

  /// VibeCoding 是否正在执行（编辑器需锁定）
  bool get vibeBusy => _vibeBusy;

  /// VibeCoding 期间的模型输出（Agent 面板展示「思考过程」）
  String get vibeThinking => _vibeThinking;

  /// 是否可用（内置模型需登录；自定义模型需完整配置）
  bool get isConfigured => _resolveLlm() != null;

  /// 当前模型展示名称
  String get currentModelName => _resolveLlm()?.name ?? '未选择模型';

  /// 供独立 Agent（设计稿 AI）复用的模型配置
  ({String apiBase, String apiKey, String model})? get llmTarget {
    final llm = _resolveLlm();
    if (llm == null) return null;
    return (apiBase: llm.apiBase, apiKey: llm.apiKey, model: llm.model);
  }

  /// 当前是否使用内置模型
  bool get isUsingBuiltinModel => _resolveLlm()?.builtin ?? false;

  /// 当前模型是否支持图片理解
  bool get currentModelSupportsVision => _resolveLlm()?.supportsVision ?? true;

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
            supportsVision: selected.supportsVision,
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
    await ProjectAgentSettingsService.instance.ensureLoaded();
    final path = _project.projectPath;
    final isolated = ProjectAgentSettingsService.instance.isIsolated(path);
    await extensions.ensureLoaded(
      scopeKey: isolated && path != null && path.isNotEmpty
          ? ProjectAgentSettingsService.scopeKeyFor(path)
          : null,
    );
    try {
      _toolbox.externalManager = ExternalMcpManager.instance;
      await ExternalMcpManager.instance.configure(extensions.enabledServers);
    } catch (e) {
      debugPrint('第三方 MCP 初始化失败：$e');
    }
    return extensions.enabledSkillsText;
  }

  /// 当前项目作用域（每个项目独立的 AI 会话）
  String get _projectScope {
    final path = _project.projectPath;
    if (path == null || path.isEmpty) return 'global';
    return ProjectAgentSettingsService.scopeKeyFor(path);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// 重新加载第三方 MCP 工具（新增 / 编辑 / 启用服务器后调用）
  Future<void> refreshMcpTools() async {
    await _prepareExtensions();
    _safeNotify();
  }

  /// /expmod：让 AI 按固定复盘规范总结本轮项目完成过程
  ///
  /// 与「直接保存最后一条回复」不同，这里会额外发起一次非流式总结，
  /// 产出结构化经验文档（背景/步骤/决策/踩坑/可复用经验/验证方式）。
  Future<String?> summarizeExperienceForKnowledge() async {
    final llm = _resolveLlm();
    if (llm == null) return null;
    final recent = _messages.length > 30
        ? _messages.sublist(_messages.length - 30)
        : _messages;
    final transcript = recent
        .where((m) => m.role != ChatRole.tool && m.content.trim().isNotEmpty)
        .map((m) => '${m.role == ChatRole.user ? '用户' : 'AI'}：${m.content}')
        .join('\n\n');
    if (transcript.trim().isEmpty) return null;
    const spec = '你是项目经验沉淀助手。请根据下面的项目任务对话，'
        '输出一份可直接存入团队知识库的中文 Markdown 经验文档，严格按以下结构：\n'
        '# 背景与目标\n'
        '# 实施方案与步骤\n'
        '# 关键决策与原因\n'
        '# 遇到的问题与解决方式\n'
        '# 可复用的经验（要点清单）\n'
        '# 验证方式\n'
        '# 适用场景与注意事项\n'
        '要求：只输出文档正文；如实归纳，不要编造未发生的内容；总长度不超过 1200 字。';
    try {
      return await LlmService.instance.chat(
        apiBase: llm.apiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        messages: [
          const ChatMessage(role: ChatRole.system, content: spec),
          ChatMessage(
            role: ChatRole.user,
            content: '对话记录：\n\n$transcript',
          ),
        ],
        temperature: 0.3,
      );
    } catch (e) {
      debugPrint('生成经验总结失败：$e');
      return null;
    }
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
      scope: _projectScope,
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

  /// 开启 / 关闭设计稿优先模式（/design）
  void setDesignMode(bool value) {
    if (_designMode == value) return;
    _designMode = value;
    if (!value) _designDraft = null;
    _safeNotify();
  }

  /// 开启 / 关闭联网搜索（/search）
  void setSearchMode(bool value) {
    if (_searchMode == value) return;
    _searchMode = value;
    _safeNotify();
  }

  /// 开启 / 关闭 AI 自行添加 MCP/Skill（/mcpadd）
  void setMcpAddMode(bool value) {
    if (_mcpAddMode == value) return;
    _mcpAddMode = value;
    _safeNotify();
  }

  /// 用户确认后，退出计划模式并按最近一条计划开始执行
  Future<void> executePlan() async {
    _planMode = false;
    await sendMessage('计划已确认，请严格按照上述计划开始执行。');
  }

  // ---------------------------------------------------------------------------
  // 提问 / 计划确认 / 中断与重试
  // ---------------------------------------------------------------------------

  Future<String> _askUser(
    String question,
    List<String> options,
    bool allowCustom,
  ) {
    _questionCompleter = Completer<String>();
    _pendingQuestion = {
      'question': question,
      'options': options,
      'allowCustom': allowCustom,
    };
    _safeNotify();
    return _questionCompleter!.future;
  }

  /// 回答 AI 的提问，Agent 会带着答案继续执行
  void answerPendingQuestion(String answer) {
    final completer = _questionCompleter;
    _pendingQuestion = null;
    _questionCompleter = null;
    final text = answer.trim();
    if (completer != null && !completer.isCompleted) {
      completer.complete(text.isEmpty ? '（用户未填写）' : text);
    }
    _safeNotify();
  }

  Future<bool> _submitPlan(String title, String markdown) {
    _planCompleter = Completer<bool>();
    _pendingPlan = {'title': title, 'markdown': markdown};
    _safeNotify();
    return _planCompleter!.future;
  }

  /// 用户确认 / 拒绝计划
  void resolvePlanConfirm(bool approved) {
    final completer = _planCompleter;
    _pendingPlan = null;
    _planCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    if (approved) {
      _planMode = false;
      _planApprovedInRun = true;
    }
    _safeNotify();
  }

  /// 强制中断当前生成（包括等待用户回答 / 确认计划的暂停状态）
  void cancel() {
    if (_status != AiStatus.thinking &&
        _pendingQuestion == null &&
        _pendingPlan == null) {
      return;
    }
    _cancelRequested = true;
    _pendingQuestion = null;
    final question = _questionCompleter;
    _questionCompleter = null;
    if (question != null && !question.isCompleted) {
      question.complete('用户已中断本次任务');
    }
    _pendingPlan = null;
    final plan = _planCompleter;
    _planCompleter = null;
    if (plan != null && !plan.isCompleted) {
      plan.complete(false);
    }
    _status = AiStatus.idle;
    _isStreaming = false;
    _streamingText = '';
    _streamingReasoning = '';
    _error = '已中断 AI 生成';
    _safeNotify();
  }

  /// 重试上一条用户消息（生成失败或被中断后可用）
  Future<void> retryLast() async {
    final text = _lastUserText;
    if (text == null || text.trim().isEmpty || isThinking) return;
    // 回滚到最后一条用户消息之前，避免重复气泡
    while (_timeline.isNotEmpty && _timeline.last is! ChatMessage) {
      _timeline.removeLast();
    }
    if (_timeline.isNotEmpty &&
        _timeline.last is ChatMessage &&
        (_timeline.last as ChatMessage).role == ChatRole.user) {
      _timeline.removeLast();
    }
    if (_messages.isNotEmpty && _messages.last.role == ChatRole.user) {
      _messages.removeLast();
    }
    _error = null;
    _status = AiStatus.idle;
    _safeNotify();
    await sendMessage(text);
  }

  /// 发送一条用户消息，Agent 会自动调用工具完成任务（流式输出）
  ///
  /// [images] 为图片附件（多模态输入）；[attachmentContext] 为文本附件内容，
  /// 只发送给模型，不直接展示在对话气泡中。
  Future<void> sendMessage(
    String text, {
    List<ChatImageAttachment> images = const [],
    String attachmentContext = '',
    List<String> attachmentNames = const [],
  }) async {
    if (text.trim().isEmpty && images.isEmpty && attachmentContext.isEmpty) {
      return;
    }
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

    // 图片需要当前模型开启「图片理解」
    if (images.isNotEmpty && !llm.supportsVision) {
      _error = '当前模型不支持图片理解，请在模型配置中开启支持图片的模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    final extraSkill = await _prepareExtensions();

    // 指令附带的动态 MCP 工具（/design /search /mcpadd）
    final extraTools = <McpTool>[];
    var commandContext = '';
    if (_searchMode) {
      extraTools.add(_buildWebSearchTool());
    }
    if (_mcpAddMode) {
      extraTools.addAll(_buildMcpAddTools());
    }
    if (_designMode) {
      _designDraft ??= await _createAiDesignDraft(text);
      final toolkit = DesignToolkit(
        draft: _designDraft!,
        onChanged: () {},
      );
      extraTools.addAll(toolkit.tools);
      commandContext = '\n\n[设计稿优先模式]\n'
          '请先使用 design_* 工具完善设计稿（id=${_designDraft!.id}），'
          '设计完成后基于该蓝图继续执行用户的实现需求。\n'
          '${toolkit.summary}';
    }
    _toolbox.setExtraTools(extraTools);

    // 确保有当前会话（首条消息自动生成会话标题）
    ConversationService.instance.ensureCurrent(firstUserText: text);

    final displayContent = attachmentNames.isEmpty
        ? text
        : '$text\n\n📎 ${attachmentNames.join('、')}';
    final userMessage = ChatMessage(
      role: ChatRole.user,
      content: displayContent.trim(),
      apiContent: (attachmentContext.isEmpty && commandContext.isEmpty)
          ? null
          : '$text$attachmentContext$commandContext',
      images: images,
    );
    _messages.add(userMessage);
    _timeline.add(userMessage);
    _steps.clear();
    _todos = const [];
    _pendingQuestion = null;
    _pendingPlan = null;
    _cancelRequested = false;
    _lastUserText = text.trim();
    _planApprovedInRun = false;
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

    // 任务实况通知（类灵动岛）：AI 执行期间可更新进度
    final liveNotify = _s.liveNotifications;
    LiveTaskService.instance.configure(enabled: liveNotify);
    if (liveNotify) {
      await LiveTaskService.ensurePermission();
      await LiveTaskService.instance.start(
        id: 'ai',
        kind: 'ai',
        title: 'SLIPE AI 正在执行',
        text: '正在分析需求…',
      );
    }
    var liveTextNotified = false;

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
          if (liveNotify) {
            final label = step.summary.isEmpty ? step.tool : step.summary;
            unawaited(
              LiveTaskService.instance.update(
                id: 'ai',
                kind: 'ai',
                title: 'SLIPE AI 正在执行',
                text: label,
                progress: null,
                indeterminate: true,
              ),
            );
          }
          _safeNotify();
        },
        onDelta: (delta) {
          onDelta(delta);
          if (liveNotify && !liveTextNotified) {
            liveTextNotified = true;
            unawaited(
              LiveTaskService.instance.update(
                id: 'ai',
                kind: 'ai',
                title: 'SLIPE AI 正在执行',
                text: '正在生成回复…',
                progress: null,
                indeterminate: true,
              ),
            );
          }
        },
        onReasoning: onReasoning,
        extraSystemPrompt: extraSkill,
        planOnly: planOnly,
        isCancelled: () => _cancelRequested,
      );
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      final reply = ChatMessage(
        role: ChatRole.assistant,
        content: result.content,
        reasoning: result.reasoning.isEmpty ? null : result.reasoning,
        kind: (planOnly && !_planApprovedInRun) ? 'plan' : 'normal',
        segments: _streamSegments.isEmpty
            ? null
            : List<ChatSegment>.from(_streamSegments),
      );
      _messages.add(reply);
      _timeline.add(reply);
      _status = AiStatus.idle;
      // 计划产出后自动退出计划模式，等待用户确认执行
      if (planOnly) _planMode = false;
      if (liveNotify) {
        unawaited(
          LiveTaskService.instance.finish(
            id: 'ai',
            kind: 'ai',
            title: 'SLIPE AI',
            text: (planOnly && !_planApprovedInRun)
                ? '计划已生成，等待确认'
                : '任务已完成',
          ),
        );
      }
    } catch (e) {
      _isStreaming = false;
      _streamingText = '';
      _streamingReasoning = '';
      _error = e is AgentCancelled ? '已中断 AI 生成' : '$e';
      _status = AiStatus.error;
      if (liveNotify) unawaited(LiveTaskService.instance.stop('ai'));
    } finally {
      _pendingQuestion = null;
      _pendingPlan = null;
      _cancelRequested = false;
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

  /// 切换项目后重置对话、作用域与指令模式（每个项目独立会话）
  Future<void> handleProjectChanged() async {
    _messages.clear();
    _timeline.clear();
    _steps.clear();
    _streamSegments.clear();
    _streamingText = '';
    _streamingReasoning = '';
    _isStreaming = false;
    _status = AiStatus.idle;
    _error = null;
    _todos = const [];
    _pendingQuestion = null;
    _pendingPlan = null;
    _historyLoaded = false;
    _designDraft = null;
    _designMode = false;
    _searchMode = false;
    _mcpAddMode = false;
    _safeNotify();
    await ensureCloudHistoryLoaded();
  }

  /// 创建一份 AI 设计稿（/design 指令首次触发时）
  Future<DesignDraft> _createAiDesignDraft(String text) async {
    final now = DateTime.now();
    final raw = text.trim().replaceAll('\n', ' ');
    final suffix = raw.isEmpty
        ? ''
        : ' · ${raw.length > 18 ? '${raw.substring(0, 18)}…' : raw}';
    final draft = DesignDraft(
      id: 'draft_${now.microsecondsSinceEpoch}',
      name: 'AI 设计稿$suffix',
      createdAt: now,
      updatedAt: now,
      root: RootPayloadInstance(specId: RootPayloadRegistry.defaultId),
      systems: [],
    );
    await DesignDraftService.instance.save(draft);
    return draft;
  }

  /// /search：联网搜索工具
  McpTool _buildWebSearchTool() {
    return McpTool(
      name: 'web_search',
      description: '联网搜索网页资料（需要登录 SLIPE 账号）。适合查询最新文档、版本信息、报错资料。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索词（1-128 字符）'},
          'count': {
            'type': 'integer',
            'description': '返回条数，默认 5，最多 10',
          },
        },
        'required': ['query'],
      },
      execute: (args) async {
        final token = _account.token;
        if (token == null || !_account.isSignedIn) {
          return '错误：联网搜索需要先登录 SLIPE 账号';
        }
        final query = (args['query'] ?? '').toString().trim();
        if (query.isEmpty) return '错误：缺少搜索词';
        final count = ((args['count'] as num?)?.toInt() ?? 5).clamp(1, 10);
        try {
          final hits = await WebSearchService.instance.search(
            accountToken: token,
            query: query,
            count: count,
          );
          return WebSearchService.formatHits(hits, query);
        } catch (e) {
          return '错误：$e';
        }
      },
    );
  }

  /// /mcpadd：允许 AI 自行注册 MCP 服务器 / Skill
  List<McpTool> _buildMcpAddTools() {
    return [
      McpTool(
        name: 'add_mcp_server',
        description: '添加一个外源 MCP 服务器（http/sse 填 url，stdio 填 command 与 args）。',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '服务器名称'},
            'transport': {
              'type': 'string',
              'description': 'http / sse / stdio，默认 http',
            },
            'url': {'type': 'string', 'description': 'http/sse 的地址'},
            'command': {'type': 'string', 'description': 'stdio 命令，如 npx'},
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'stdio 命令参数',
            },
          },
          'required': ['name'],
        },
        execute: (args) async {
          final name = (args['name'] ?? '').toString().trim();
          if (name.isEmpty) return '错误：缺少服务器名称';
          var transport = (args['transport'] ?? '').toString().trim();
          final url = (args['url'] ?? '').toString().trim();
          final command = (args['command'] ?? '').toString().trim();
          if (transport.isEmpty) {
            transport = command.isNotEmpty ? 'stdio' : 'http';
          }
          if (transport != 'stdio' && url.isEmpty) {
            return '错误：http/sse 服务器需要 url';
          }
          if (transport == 'stdio' && command.isEmpty) {
            return '错误：stdio 服务器需要 command';
          }
          final rawArgs = args['args'];
          final cmdArgs = rawArgs is List
              ? rawArgs.map((e) => e.toString()).toList()
              : rawArgs is String && rawArgs.trim().isNotEmpty
                  ? rawArgs.trim().split(RegExp(r'\s+'))
                  : <String>[];
          await AiExtensionsService.instance.addServer(
            name: name,
            transport: transport,
            url: url,
            command: command,
            args: cmdArgs,
          );
          await ExternalMcpManager.instance.refresh(
            AiExtensionsService.instance.enabledServers,
          );
          return '已添加 MCP 服务器「$name」（$transport）';
        },
      ),
      McpTool(
        name: 'add_skill',
        description: '添加一个外源 Skill（一段会追加到系统提示词的经验/规范文本）。',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'Skill 名称'},
            'content': {'type': 'string', 'description': 'Skill 正文（Markdown）'},
          },
          'required': ['name', 'content'],
        },
        execute: (args) async {
          final name = (args['name'] ?? '').toString().trim();
          final content = (args['content'] ?? '').toString().trim();
          if (name.isEmpty || content.isEmpty) {
            return '错误：name 与 content 不能为空';
          }
          await AiExtensionsService.instance.addSkill(
            name: name,
            content: content,
          );
          return '已添加 Skill「$name」';
        },
      ),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
