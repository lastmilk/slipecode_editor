import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// AI 对话记录本地存储（可选再同步到云端）
///
/// 只保存 role/content/ts，最多 200 条，避免 SharedPreferences 过大。
class ChatHistoryService {
  ChatHistoryService._();

  static final ChatHistoryService instance = ChatHistoryService._();

  static const _key = 'slipecode_chat_history';
  static const _maxEntries = 200;

  Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Map<String, dynamic>> messages) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = messages.length > _maxEntries
        ? messages.sublist(messages.length - _maxEntries)
        : messages;
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
