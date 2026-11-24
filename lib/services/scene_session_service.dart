import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scene.dart';

/// 场景草稿：一次场景工作台会话的本地快照。
class SceneDraft {
  final String sessionId;
  final SceneSelection selection;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 场景自定义数据（素材、分镜、任务参数、文档内容、对话与记忆等）。
  final Map<String, dynamic> payload;

  const SceneDraft({
    required this.sessionId,
    required this.selection,
    required this.createdAt,
    required this.updatedAt,
    this.payload = const {},
  });

  SceneDraft copyWith({
    String? sessionId,
    SceneSelection? selection,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? payload,
  }) {
    return SceneDraft(
      sessionId: sessionId ?? this.sessionId,
      selection: selection ?? this.selection,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      payload: payload ?? this.payload,
    );
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'selection': selection.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'payload': payload,
      };

  factory SceneDraft.fromJson(Map<String, dynamic> json) {
    final rawSelection = json['selection'];
    final rawPayload = json['payload'];
    return SceneDraft(
      sessionId: json['sessionId'] as String? ?? '',
      selection: rawSelection is Map
          ? SceneSelection.fromJson(rawSelection.cast<String, dynamic>())
          : const SceneSelection(sceneId: ''),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      payload: rawPayload is Map
          ? rawPayload.cast<String, dynamic>()
          : const <String, dynamic>{},
    );
  }
}

/// 场景选择记忆与本地草稿服务。
///
/// - 上次选择：SharedPreferences，键 `scene.last_selection.v1`。
/// - 草稿：应用支持目录 `scene_drafts/<sessionId>.json`。
///
/// 所有读写均自行兜底，异常不会冒泡到 UI。
class SceneSessionService {
  SceneSessionService._();

  static final SceneSessionService instance = SceneSessionService._();

  static const String _selectionKey = 'scene.last_selection.v1';
  static const String _draftDirName = 'scene_drafts';

  // ---------------- 上次选择 ----------------

  Future<SceneSelection?> loadLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_selectionKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final selection =
          SceneSelection.fromJson(decoded.cast<String, dynamic>());
      if (selection.sceneId.isEmpty) return null;
      return selection;
    } catch (e) {
      debugPrint('读取场景上次选择失败：$e');
      return null;
    }
  }

  Future<void> saveLastSelection(SceneSelection selection) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectionKey, jsonEncode(selection.toJson()));
    } catch (e) {
      debugPrint('保存场景上次选择失败：$e');
    }
  }

  // ---------------- 草稿 ----------------

  /// 新建草稿并立即落盘。
  Future<SceneDraft> createDraft(
    SceneSelection selection, {
    Map<String, dynamic>? payload,
  }) async {
    final now = DateTime.now();
    final draft = SceneDraft(
      sessionId: 'scene_${now.microsecondsSinceEpoch}',
      selection: selection,
      createdAt: now,
      updatedAt: now,
      payload: payload ?? const <String, dynamic>{},
    );
    await saveDraft(draft);
    return draft;
  }

  Future<SceneDraft?> loadDraft(String sessionId) async {
    try {
      final file = await _draftFile(sessionId);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SceneDraft.fromJson(decoded.cast<String, dynamic>());
    } catch (e) {
      debugPrint('读取场景草稿失败：$e');
      return null;
    }
  }

  Future<void> saveDraft(SceneDraft draft) async {
    try {
      final file = await _draftFile(draft.sessionId);
      await file.writeAsString(jsonEncode(draft.toJson()), flush: true);
    } catch (e) {
      debugPrint('保存场景草稿失败：$e');
    }
  }

  /// 列出全部草稿，按更新时间倒序。
  Future<List<SceneDraft>> listDrafts() async {
    try {
      final dir = await _draftDir();
      if (!await dir.exists()) return [];
      final drafts = <SceneDraft>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is! Map) continue;
          final draft = SceneDraft.fromJson(decoded.cast<String, dynamic>());
          if (draft.sessionId.isEmpty) continue;
          drafts.add(draft);
        } catch (e) {
          debugPrint('跳过损坏的场景草稿 ${entity.path}：$e');
        }
      }
      drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return drafts;
    } catch (e) {
      debugPrint('枚举场景草稿失败：$e');
      return [];
    }
  }

  Future<void> deleteDraft(String sessionId) async {
    try {
      final file = await _draftFile(sessionId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('删除场景草稿失败：$e');
    }
  }

  Future<Directory> _draftDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _draftDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _draftFile(String sessionId) async {
    final dir = await _draftDir();
    final safeId = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return File(p.join(dir.path, '$safeId.json'));
  }
}
