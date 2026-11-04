import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/design_draft.dart';

/// 设计稿本地持久化
///
/// 设计稿是用户的编排资产，保存在本机
/// （SharedPreferences，键 `design_drafts`，JSON 数组）。
class DesignDraftService {
  DesignDraftService._();

  static final DesignDraftService instance = DesignDraftService._();

  static const _key = 'design_drafts';

  Future<List<DesignDraft>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final list = decoded
          .map((e) => DesignDraft.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(DesignDraft draft) async {
    final items = await list();
    items.removeWhere((d) => d.id == draft.id);
    draft.updatedAt = DateTime.now();
    items.insert(0, draft);
    await _persist(items);
  }

  Future<void> delete(String id) async {
    final items = await list();
    items.removeWhere((d) => d.id == id);
    await _persist(items);
  }

  Future<DesignDraft?> byId(String id) async {
    final items = await list();
    for (final d in items) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> _persist(List<DesignDraft> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(items.map((d) => d.toMap()).toList()),
    );
  }
}
