import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/knowledge_entry.dart';
import 'account_service.dart';

/// 私人知识库
///
/// - 本地持久化（SharedPreferences）；
/// - 登录账号后与云端同步（GET/PUT /api/me/knowledge），进入账号云同步体系；
/// - 供 AI 通过 `/exp` 读取经验、通过 `/expmod` 写入经验。
class KnowledgeService extends ChangeNotifier {
  KnowledgeService._();

  static final KnowledgeService instance = KnowledgeService._();

  static const _key = 'slipe_knowledge_base';
  static const _metaKey = 'slipe_knowledge_updated_at';

  final List<KnowledgeEntry> _items = [];
  bool _loaded = false;
  bool _syncing = false;
  DateTime _updatedAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<KnowledgeEntry> get items => List.unmodifiable(_items);
  bool get loaded => _loaded;
  bool get syncing => _syncing;

  /// 启动时加载本地知识库
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          if (item is Map) {
            _items.add(
              KnowledgeEntry.fromMap(Map<String, dynamic>.from(item)),
            );
          }
        }
      } catch (_) {
        // 损坏数据直接忽略，避免阻塞启动
      }
    }
    _sort();
    _updatedAt = DateTime.tryParse(prefs.getString(_metaKey) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    _loaded = true;
    notifyListeners();
  }

  void _sort() {
    _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _persist({bool touch = true}) async {
    _sort();
    if (touch) _updatedAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_items.map((e) => e.toMap()).toList()),
    );
    await prefs.setString(_metaKey, _updatedAt.toIso8601String());
    notifyListeners();
  }

  /// 新增 / 更新一条知识
  Future<KnowledgeEntry> upsert({
    required String title,
    required String content,
    List<String> tags = const [],
    String source = 'manual',
    String sourceId = '',
    String? id,
  }) async {
    await ensureLoaded();
    final now = DateTime.now();
    final existingIndex = id == null
        ? -1
        : _items.indexWhere((e) => e.id == id);
    late KnowledgeEntry entry;
    if (existingIndex >= 0) {
      entry = _items[existingIndex]
          .copyWith(
            title: title.trim().isEmpty ? '未命名知识' : title.trim(),
            content: content,
            tags: tags,
            source: source,
            sourceId: sourceId,
            updatedAt: now,
          );
      _items[existingIndex] = entry;
    } else {
      entry = KnowledgeEntry(
        id: 'kb_${now.microsecondsSinceEpoch}',
        title: title.trim().isEmpty ? '未命名知识' : title.trim(),
        content: content,
        source: source,
        sourceId: sourceId,
        tags: tags,
        createdAt: now,
        updatedAt: now,
      );
      _items.add(entry);
    }
    await _persist();
    return entry;
  }

  Future<void> delete(String id) async {
    await ensureLoaded();
    _items.removeWhere((e) => e.id == id);
    await _persist();
  }

  /// 把官方文档复制进知识库（同一文档已存在时更新）
  Future<KnowledgeEntry> importFromDoc({
    required String docId,
    required String title,
    required String content,
    bool forceNew = false,
  }) async {
    await ensureLoaded();
    KnowledgeEntry? existing;
    if (!forceNew) {
      for (final entry in _items) {
        if (entry.sourceId.isNotEmpty && entry.sourceId == docId) {
          existing = entry;
          break;
        }
      }
    }
    return upsert(
      id: existing?.id,
      title: title,
      content: content,
      source: 'official',
      sourceId: docId,
      tags: const ['官方文档'],
    );
  }

  /// 生成给 AI 参考的知识上下文（/exp）
  String buildContext({int maxChars = 8000}) {
    if (_items.isEmpty) return '';
    final buffer = StringBuffer();
    for (final entry in _items) {
      final block = '### ${entry.title}\n${entry.content}\n\n';
      if (buffer.length + block.length > maxChars) break;
      buffer.write(block);
    }
    if (buffer.isEmpty) return '';
    return '\n\n以下是我的私人知识库经验，请优先参考：\n\n$buffer';
  }

  List<Map<String, dynamic>> toJsonList() =>
      _items.map((e) => e.toMap()).toList();

  /// 把一次 AI 回复沉淀为经验条目（/expmod）
  Future<KnowledgeEntry?> saveExperience(
    String content, {
    String? title,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return null;
    String resolvedTitle;
    if (title != null && title.trim().isNotEmpty) {
      resolvedTitle = title.trim();
    } else {
      final firstLine = text
          .split('\n')
          .firstWhere((line) => line.trim().isNotEmpty, orElse: () => 'AI 经验')
          .replaceAll(RegExp(r'^[#>\-\s`*]+'), '')
          .trim();
      resolvedTitle = firstLine.length > 40
          ? '${firstLine.substring(0, 40)}…'
          : (firstLine.isEmpty ? 'AI 经验总结' : firstLine);
    }
    return upsert(
      title: resolvedTitle,
      content: text,
      source: 'ai',
      tags: const ['AI 经验'],
    );
  }

  /// 与云端同步：按整库更新时间做「最后写入优先」，
  /// 这样删除条目也能正确同步（而不是被云端旧条目合并回来）。
  Future<void> sync(String? token) async {
    await ensureLoaded();
    if (token == null || token.isEmpty || _syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      final remote = await AccountService.instance.fetchKnowledge(token);
      if (remote == null) return;
      final remoteItems = <String, KnowledgeEntry>{};
      for (final map in remote.items) {
        final entry = KnowledgeEntry.fromMap(map);
        if (entry.id.isNotEmpty) remoteItems[entry.id] = entry;
      }

      // 本地为空时直接采用云端（首次登录 / 新设备）
      if (_items.isEmpty && remoteItems.isNotEmpty) {
        _items.addAll(remoteItems.values);
        _updatedAt = remote.updatedAt ?? DateTime.now();
        await _persist(touch: false);
        return;
      }

      final remoteUpdated = remote.updatedAt ??
          remoteItems.values
              .fold<DateTime?>(
                null,
                (max, e) =>
                    max == null || e.updatedAt.isAfter(max) ? e.updatedAt : max,
              ) ??
          DateTime.fromMillisecondsSinceEpoch(0);

      if (remoteItems.isNotEmpty &&
          remoteUpdated.isAfter(_updatedAt)) {
        // 云端更新 → 覆盖本地（包含云端发生的删除）
        _items
          ..clear()
          ..addAll(remoteItems.values);
        _updatedAt = remoteUpdated;
        await _persist(touch: false);
      } else {
        // 本地更新 → 覆盖云端
        await AccountService.instance.pushKnowledge(
          token,
          toJsonList(),
          updatedAt: _updatedAt,
        );
      }
    } catch (e) {
      debugPrint('知识库同步失败：$e');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
