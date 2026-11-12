import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 项目级 Agent 设置
///
/// - `isolated = true`：该项目使用独立的 MCP / Skills（与其它项目隔离）；
/// - 会话永远按项目隔离（由 ConversationService 使用 [scopeKeyFor]）。
class ProjectAgentSettingsService {
  ProjectAgentSettingsService._();

  static final ProjectAgentSettingsService instance =
      ProjectAgentSettingsService._();

  static const _key = 'slipe_project_agent_settings_v1';

  final Map<String, bool> _isolated = {};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final data = jsonDecode(raw);
        if (data is Map) {
          for (final entry in data.entries) {
            _isolated['${entry.key}'] = entry.value == true;
          }
        }
      } catch (_) {
        // 损坏数据忽略
      }
    }
    _loaded = true;
  }

  bool isIsolated(String? projectPath) {
    if (projectPath == null || projectPath.isEmpty) return false;
    return _isolated[projectPath] == true;
  }

  Future<void> setIsolated(String projectPath, bool value) async {
    await ensureLoaded();
    if (projectPath.isEmpty) return;
    _isolated[projectPath] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_isolated));
  }

  /// 稳定的项目作用域标识（用于本地会话与 MCP/Skills 存储键）
  static String scopeKeyFor(String projectPath) {
    // FNV-1a 32bit：跨平台稳定，避免依赖 String.hashCode
    var hash = 0x811c9dc5;
    for (final unit in projectPath.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
