import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/chat_segment.dart';
import 'account_service.dart';
import 'chat_history_service.dart';
import 'llm_service.dart';
import 'network_policy.dart';

/// 一条 AI 会话（DeepSeek 风格侧边栏的一项）
class AiConversation {
  AiConversation({
    required this.id,
    required this.title,
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
    List<ChatMessage>? messages,
    this.synced = false,
  }) : messages = messages ?? [];

  final String id;
  String title;
  bool pinned;
  final int createdAt;
  int updatedAt;
  List<ChatMessage> messages;

  /// 是否已存在于云端（本地新建的会话首次同步前置为 false）
  bool synced;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'pinned': pinned,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'synced': synced,
        'messages': messages.map(ConversationService.messageToJson).toList(),
      };

  factory AiConversation.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    return AiConversation(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '新的对话').toString(),
      pinned: json['pinned'] == true,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      synced: json['synced'] == true,
      messages: rawMessages is List
          ? rawMessages
              .whereType<Map>()
              .map((e) => ConversationService.messageFromJson(
                  Map<String, dynamic>.from(e)))
              .toList()
          : [],
    );
  }
}

/// AI 多会话管理：本地持久化 + 登录后跨端同步
///
/// - 本地 SharedPreferences 为离线真相，按用户隔离存储；
/// - 登录后与云端合并：远端新会话拉取全文，本地新会话上传，冲突按 updatedAt 新者胜；
/// - 消息变更防抖 2 秒全量推送。
class ConversationService extends ChangeNotifier {
  ConversationService._();

  static final ConversationService instance = ConversationService._();

  static const _keyPrefix = 'slipe_conversations_v1_';
  static const _maxLocal = 200;

  List<AiConversation> _list = [];
  String _userKey = 'anon';
  bool _loaded = false;
  bool _cloudSynced = false;
  bool _cloudEnabled = false;
  String? _token;
  final Map<String, Timer> _pushTimers = {};

  /// 项目作用域：每个项目拥有独立的 AI 会话
  String _scope = 'global';

  /// 会话 id 前缀（用于区分云端不同项目的会话）
  String _idPrefix = '';

  String get _localKey => '$_keyPrefix${_userKey}__$_scope';

  /// 当前打开的会话 id（null 表示尚未创建/选择）
  String? currentId;

  /// 会话列表（置顶在前，其余按更新时间倒序）
  List<AiConversation> get conversations {
    final copy = List<AiConversation>.from(_list);
    copy.sort((a, b) {
      final pin = (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);
      if (pin != 0) return pin;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return copy;
  }

  AiConversation? get current {
    final id = currentId;
    if (id == null) return null;
    for (final c in _list) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 消息序列化（供会话存储与云同步共用）
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> messageToJson(ChatMessage m) => {
        'role': m.role == ChatRole.assistant ? 'assistant' : 'user',
        'content': m.content,
        if (m.apiContent != null && m.apiContent != m.content)
          'apiContent': m.apiContent,
        if (m.reasoning != null && m.reasoning!.isNotEmpty)
          'reasoning': m.reasoning,
        if (m.kind != 'normal') 'kind': m.kind,
        if (m.segments != null && m.segments!.isNotEmpty)
          'segments': m.segments!.map((s) => s.toJson()).toList(),
        'ts': DateTime.now().millisecondsSinceEpoch,
      };

  static ChatMessage messageFromJson(Map<String, dynamic> json) {
    final reasoning = (json['reasoning'] ?? '').toString();
    final apiContent = (json['apiContent'] ?? '').toString();
    return ChatMessage(
      role: json['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user,
      content: (json['content'] ?? '').toString(),
      reasoning: reasoning.isEmpty ? null : reasoning,
      kind: (json['kind'] ?? 'normal').toString(),
      segments: ChatSegment.listFromJson(json['segments']),
      apiContent: apiContent.isEmpty ? null : apiContent,
    );
  }

  // ---------------------------------------------------------------------------
  // 加载与本地持久化
  // ---------------------------------------------------------------------------

  /// 按当前用户加载本地会话（用户切换时重新加载）
  ///
  /// [userId] 为空字符串表示未登录（匿名本地会话）；
  /// [cloudEnabled] 表示设置中开启了对话云同步。
  Future<void> ensureLoaded({
    required String userId,
    String? token,
    bool cloudEnabled = false,
    AppSettings? settings,
    String scope = 'global',
  }) async {
    final key = userId.isEmpty ? 'anon' : userId;
    final accountChanged = key != _userKey;
    _token = token;
    _cloudEnabled = cloudEnabled && token != null;
    if (_loaded && !accountChanged) {
      if (scope != _scope) {
        await switchScopeInternal(scope, settings: settings);
        return;
      }
      // 登录状态刚就绪时补一次云同步
      if (_cloudEnabled && !_cloudSynced) unawaited(_syncWithCloud(settings));
      return;
    }
    _userKey = key;
    _scope = scope;
    _idPrefix = scope == 'global' ? '' : 'p${scope}_';
    _loaded = true;
    _cloudSynced = false;
    currentId = null;
    _list = await _readLocal();
    if (_list.isEmpty && scope == 'global') {
      await _migrateLegacy();
    }
    // 自动恢复最近一次使用的会话
    if (currentId == null && _list.isNotEmpty) {
      currentId = conversations.first.id;
    }
    notifyListeners();
    if (_cloudEnabled) unawaited(_syncWithCloud(settings));
  }

  /// 切换项目作用域（切换项目后重新加载该项目的独立会话）
  Future<void> switchScopeInternal(
    String scope, {
    AppSettings? settings,
  }) async {
    if (scope == _scope && _loaded) return;
    await _saveLocal();
    _scope = scope;
    _idPrefix = scope == 'global' ? '' : 'p${scope}_';
    _cloudSynced = false;
    currentId = null;
    _list = await _readLocal();
    if (currentId == null && _list.isNotEmpty) {
      currentId = conversations.first.id;
    }
    notifyListeners();
    if (_cloudEnabled) unawaited(_syncWithCloud(settings));
  }

  Future<List<AiConversation>> _readLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 兼容升级前按用户存储的全局会话
      final raw = prefs.getString(_localKey) ??
          (_scope == 'global'
              ? prefs.getString('$_keyPrefix$_userKey')
              : null);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => AiConversation.fromJson(Map<String, dynamic>.from(e)))
          .where((c) => c.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('读取本地会话失败：$e');
      return [];
    }
  }

  /// 旧版单会话记录迁移为一条会话
  Future<void> _migrateLegacy() async {
    try {
      final records = await ChatHistoryService.instance.load();
      if (records.isEmpty) return;
      final messages = records
          .where((e) => (e['content'] ?? '').toString().isNotEmpty)
          .map((e) {
        final reasoning = (e['reasoning'] ?? '').toString();
        return ChatMessage(
          role:
              e['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user,
          content: (e['content'] ?? '').toString(),
          reasoning: reasoning.isEmpty ? null : reasoning,
        );
      }).toList();
      if (messages.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final conv = AiConversation(
        id: _newId(),
        title: _titleFrom(messages),
        createdAt: now,
        updatedAt: now,
        messages: messages,
      );
      _list.add(conv);
      await _saveLocal();
      await ChatHistoryService.instance.clear();
    } catch (e) {
      debugPrint('迁移旧对话记录失败：$e');
    }
  }

  Future<void> _saveLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 本地最多保留 _maxLocal 条（置顶的优先保留）
      final sorted = conversations;
      final kept = sorted.take(_maxLocal).toList();
      await prefs.setString(
        _localKey,
        jsonEncode(kept.map((c) => c.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('保存本地会话失败：$e');
    }
  }

  String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().hashCode & 0xFFFFFF).toRadixString(36);
    return '${_idPrefix}c$now$rand';
  }

  static String _titleFrom(List<ChatMessage> messages) {
    for (final m in messages) {
      if (m.role == ChatRole.user && m.content.trim().isNotEmpty) {
        final text = m.content.trim().replaceAll('\n', ' ');
        return text.length > 24 ? '${text.substring(0, 24)}…' : text;
      }
    }
    return '新的对话';
  }

  // ---------------------------------------------------------------------------
  // 会话操作
  // ---------------------------------------------------------------------------

  /// 新建空会话并设为当前
  AiConversation createLocal({String? title}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = AiConversation(
      id: _newId(),
      title: title ?? '新的对话',
      createdAt: now,
      updatedAt: now,
    );
    _list.add(conv);
    currentId = conv.id;
    _saveLocal();
    notifyListeners();
    _pushMeta(conv);
    return conv;
  }

  /// 确保存在当前会话：没有则按首条用户消息建会话并自动命名
  AiConversation ensureCurrent({String? firstUserText}) {
    final existing = current;
    if (existing != null) return existing;
    final conv = createLocal(
      title: firstUserText == null || firstUserText.trim().isEmpty
          ? null
          : (firstUserText.trim().replaceAll('\n', ' ').length > 24
              ? '${firstUserText.trim().replaceAll('\n', ' ').substring(0, 24)}…'
              : firstUserText.trim().replaceAll('\n', ' ')),
    );
    return conv;
  }

  /// 打开一个会话
  void open(String id) {
    if (currentId == id) return;
    currentId = id;
    notifyListeners();
  }

  /// 更新当前会话消息（触发本地保存与云端防抖推送）
  void updateMessages(String id, List<ChatMessage> messages) {
    final conv = _list.where((c) => c.id == id).firstOrNull;
    if (conv == null) return;
    conv.messages = List<ChatMessage>.from(messages);
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    // 首条用户消息进来后自动命名
    if (conv.title == '新的对话') {
      conv.title = _titleFrom(conv.messages);
      _pushMeta(conv);
    }
    _saveLocal();
    notifyListeners();
    _schedulePush(conv);
  }

  Future<void> rename(String id, String title) async {
    final conv = _list.where((c) => c.id == id).firstOrNull;
    if (conv == null || title.trim().isEmpty) return;
    conv.title = title.trim();
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _saveLocal();
    notifyListeners();
    _pushMeta(conv);
  }

  Future<void> togglePin(String id) async {
    final conv = _list.where((c) => c.id == id).firstOrNull;
    if (conv == null) return;
    conv.pinned = !conv.pinned;
    await _saveLocal();
    notifyListeners();
    _pushMeta(conv);
  }

  Future<void> delete(String id) async {
    _list.removeWhere((c) => c.id == id);
    if (currentId == id) currentId = null;
    await _saveLocal();
    notifyListeners();
    final token = _token;
    if (_cloudEnabled && token != null) {
      try {
        await AccountService.instance.deleteConversation(token, id);
      } catch (e) {
        debugPrint('删除云端会话失败：$e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 云同步
  // ---------------------------------------------------------------------------

  void _pushMeta(AiConversation conv) {
    final token = _token;
    if (!_cloudEnabled || token == null) return;
    unawaited(() async {
      try {
        if (!conv.synced) {
          await AccountService.instance
              .createConversation(token, id: conv.id, title: conv.title);
          conv.synced = true;
          await _saveLocal();
        } else {
          await AccountService.instance
              .updateConversation(token, conv.id, title: conv.title, pinned: conv.pinned);
        }
      } catch (e) {
        debugPrint('同步会话元信息失败：$e');
      }
    }());
  }

  void _schedulePush(AiConversation conv) {
    final token = _token;
    if (!_cloudEnabled || token == null) return;
    _pushTimers[conv.id]?.cancel();
    _pushTimers[conv.id] = Timer(const Duration(seconds: 2), () async {
      try {
        if (!conv.synced) {
          await AccountService.instance
              .createConversation(token, id: conv.id, title: conv.title);
          conv.synced = true;
        }
        await AccountService.instance.updateConversation(
          token,
          conv.id,
          title: conv.title,
          pinned: conv.pinned,
          messages: conv.messages.map(messageToJson).toList(),
        );
      } catch (e) {
        debugPrint('推送会话失败：$e');
      }
    });
  }

  /// 与云端合并：远端新会话拉取、本地新会话上传、冲突按 updatedAt 新者胜
  Future<void> _syncWithCloud(AppSettings? settings) async {
    final token = _token;
    if (!_cloudEnabled || token == null || _cloudSynced) return;
    _cloudSynced = true;
    try {
      if (settings != null && !await NetworkPolicy.canSyncNow(settings)) {
        return;
      }
      final remoteList = await AccountService.instance.listConversations(token);
      final remoteIds = <String>{};
      var changed = false;
      for (final meta in remoteList) {
        final id = (meta['id'] ?? '').toString();
        if (id.isEmpty) continue;
        // 云端混存了所有项目的会话：只同步当前项目作用域的会话
        if (!id.startsWith(_idPrefix)) continue;
        remoteIds.add(id);
        final remoteUpdated = (meta['updatedAt'] as num?)?.toInt() ?? 0;
        final local = _list.where((c) => c.id == id).firstOrNull;
        if (local == null || remoteUpdated > local.updatedAt) {
          // 远端更新或本地缺失：拉取全文
          try {
            final full =
                await AccountService.instance.fetchConversation(token, id);
            final rawMessages = full['messages'];
            final messages = rawMessages is List
                ? rawMessages
                    .whereType<Map>()
                    .map((e) =>
                        messageFromJson(Map<String, dynamic>.from(e)))
                    .toList()
                : <ChatMessage>[];
            final conv = AiConversation(
              id: id,
              title: (full['title'] ?? '新的对话').toString(),
              pinned: full['pinned'] == true,
              createdAt: (full['createdAt'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              updatedAt: remoteUpdated,
              messages: messages,
              synced: true,
            );
            _list.removeWhere((c) => c.id == id);
            _list.add(conv);
            changed = true;
          } catch (e) {
            debugPrint('拉取会话 $id 失败：$e');
          }
        } else if (local.updatedAt > remoteUpdated || !local.synced) {
          // 本地更新：推送
          local.synced = true;
          _schedulePush(local);
        }
      }
      // 本地独有的会话上传
      for (final conv in _list) {
        if (!remoteIds.contains(conv.id) && !conv.synced) {
          conv.synced = true;
          _schedulePush(conv);
        }
      }
      if (changed) {
        await _saveLocal();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('会话云同步失败：$e');
    }
  }

  /// 登录态变化后强制重新同步
  void markCloudDirty() {
    _cloudSynced = false;
  }

  @override
  void dispose() {
    for (final timer in _pushTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
