import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../agent/mcp_tools.dart';
import '../models/app_settings.dart';
import '../providers/account_provider.dart';
import '../providers/build_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/terminal_provider.dart';
import '../services/account_service.dart';
import '../services/chat_history_service.dart';
import '../services/llm_service.dart';
import '../services/network_policy.dart';

/// AI 助手状态
enum AiStatus { idle, thinking, error }

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
      // 仅检测到 Termux 时向 Agent 暴露终端工具
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

  /// VibeCoding 是否正在执行（编辑器需锁定）
  bool get vibeBusy => _vibeBusy;

  /// VibeCoding 期间的模型输出（Agent 面板展示「思考过程」）
  String get vibeThinking => _vibeThinking;

  /// 是否已配置 LLM
  bool get isConfigured => _settings.settings.isLlmConfigured;

  AppSettings get _s => _settings.settings;

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
        final message = ChatMessage(
          role: item['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user,
          content: content,
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
    if (!isConfigured) {
      _error = '未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    final llm = _s.activeLlm;
    if (llm == null || !llm.isConfigured) {
      _error = '未配置 LLM，请在偏好设置中填写 API 地址、Key 和模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

    final userMessage = ChatMessage(role: ChatRole.user, content: text);
    _messages.add(userMessage);
    _timeline.add(userMessage);
    _steps.clear();
    _status = AiStatus.thinking;
    _error = null;
    _isStreaming = true;
    _streamingText = '';
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

    try {
      final result = await _agent.run(
        apiBase: llm.normalizedApiBase,
        apiKey: llm.apiKey,
        model: llm.model,
        history: List<ChatMessage>.from(history),
        onStep: (step) {
          if (!_steps.contains(step)) _steps.add(step);
          if (!_timeline.contains(step)) _timeline.add(step);
          _safeNotify();
        },
        onDelta: onDelta,
      );
      _isStreaming = false;
      _streamingText = '';
      final reply = ChatMessage(
        role: ChatRole.assistant,
        content: result.content,
      );
      _messages.add(reply);
      _timeline.add(reply);
      _status = AiStatus.idle;
    } catch (e) {
      _isStreaming = false;
      _streamingText = '';
      _error = '$e';
      _status = AiStatus.error;
    }
    _safeNotify();
    await _persistHistory();
  }

  /// 把当前文件的内容附加到消息中发送
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
    final llm = _s.activeLlm;
    if (llm == null || !llm.isConfigured) {
      _error = '未配置 LLM，请在「偏好设置 → AI 模型」中添加模型';
      _status = AiStatus.error;
      _safeNotify();
      return;
    }

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
        apiBase: llm.normalizedApiBase,
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
        isCancelled: () => _vibeCancelled,
      );

      await _editor.reloadFile(filePath);
      _status = AiStatus.idle;
      _vibeThinking = result.content;
    } catch (e) {
      _error = 'VibeCoding 失败：$e';
      _status = AiStatus.error;
    } finally {
      _vibeBusy = false;
      _safeNotify();
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
