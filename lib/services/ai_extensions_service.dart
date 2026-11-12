import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mcp_config.dart';

/// 第三方 MCP 服务器 + 外源 Skill 的本地配置仓库
///
/// 配置保存在本机 SharedPreferences，不上传服务端，避免 API Key 泄露。
class AiExtensionsService extends ChangeNotifier {
  AiExtensionsService._();

  static final AiExtensionsService instance = AiExtensionsService._();

  static const _storageKey = 'slipe_ai_extensions_v1';

  /// 当前作用域（null = 全局；非空 = 某个项目独立的 MCP/Skills）
  String? _scopeKey;

  String get _storageKeyForScope =>
      _scopeKey == null ? _storageKey : '${_storageKey}_$_scopeKey';

  bool _loaded = false;
  List<McpServerConfig> _servers = const [];
  List<ImportedSkill> _skills = const [];

  List<McpServerConfig> get servers => List.unmodifiable(_servers);
  List<ImportedSkill> get skills => List.unmodifiable(_skills);
  List<McpServerConfig> get enabledServers =>
      _servers.where((s) => s.enabled).toList(growable: false);

  /// 启用的外源 Skill 拼接文本（追加到系统提示词）
  String get enabledSkillsText {
    final active = _skills.where((s) => s.enabled && s.content.trim().isNotEmpty);
    if (active.isEmpty) return '';
    return active
        .map((s) => '## ${s.name}\n${s.content.trim()}')
        .join('\n\n');
  }

  /// 服务器配置签名，用于判断是否需要重连 MCP
  String get serversSignature {
    return _servers
        .where((s) => s.enabled)
        .map((s) => '${s.id}:${s.transport}:${s.url}:${s.command}:${s.args.join(',')}')
        .join('|');
  }

  /// 加载配置
  ///
  /// [scopeKey] 为空表示全局配置；非空时加载该项目独立的 MCP/Skills。
  Future<void> ensureLoaded({String? scopeKey}) async {
    if (_loaded && _scopeKey == scopeKey) return;
    _scopeKey = scopeKey;
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKeyForScope);
    _servers = const [];
    _skills = const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final data = jsonDecode(raw);
        if (data is Map) {
          final servers = data['servers'];
          final skills = data['skills'];
          if (servers is List) {
            _servers = servers
                .whereType<Map>()
                .map((e) => McpServerConfig.fromJson(Map<String, dynamic>.from(e)))
                .where((e) => e.id.isNotEmpty)
                .toList();
          }
          if (skills is List) {
            _skills = skills
                .whereType<Map>()
                .map((e) => ImportedSkill.fromJson(Map<String, dynamic>.from(e)))
                .where((e) => e.id.isNotEmpty)
                .toList();
          }
        }
      } catch (_) {
        _servers = const [];
        _skills = const [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKeyForScope,
      jsonEncode({
        'servers': _servers.map((e) => e.toJson()).toList(),
        'skills': _skills.map((e) => e.toJson()).toList(),
      }),
    );
    notifyListeners();
  }

  String _newId(String prefix) {
    final rand = Random.secure();
    final suffix = List.generate(6, (_) => rand.nextInt(16).toRadixString(16)).join();
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$suffix';
  }

  Future<McpServerConfig> addServer({
    required String name,
    required String transport,
    String url = '',
    Map<String, String> headers = const {},
    String command = '',
    List<String> args = const [],
    Map<String, String> env = const {},
  }) async {
    final server = McpServerConfig(
      id: _newId('mcp'),
      name: name.trim(),
      transport: transport,
      url: url.trim(),
      headers: headers,
      command: command.trim(),
      args: args,
      env: env,
      enabled: true,
    );
    _servers = [..._servers, server];
    await _persist();
    return server;
  }

  Future<void> updateServer(McpServerConfig server) async {
    _servers = _servers.map((s) => s.id == server.id ? server : s).toList();
    await _persist();
  }

  Future<void> removeServer(String id) async {
    _servers = _servers.where((s) => s.id != id).toList();
    await _persist();
  }

  Future<void> toggleServer(String id, bool enabled) async {
    _servers = _servers
        .map((s) => s.id == id ? s.copyWith(enabled: enabled) : s)
        .toList();
    await _persist();
  }

  /// 导入 Claude Desktop / Cursor 风格的 MCP 配置文件
  ///
  /// 支持：
  ///   {"mcpServers": {"name": {"command": "...", "args": [...]}}}
  ///   {"mcpServers": {"name": {"url": "...", "headers": {...}}}}
  ///   {"name": {...}}（顶层直接是服务器映射）
  Future<({int imported, int skipped, String? error})> importConfig(String raw) async {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (e) {
      return (imported: 0, skipped: 0, error: 'JSON 解析失败：$e');
    }
    if (data == null) {
      return (imported: 0, skipped: 0, error: '配置文件格式不正确');
    }

    final rawMap = data['mcpServers'] ?? data['servers'] ?? data;
    if (rawMap is! Map) {
      return (imported: 0, skipped: 0, error: '未找到 mcpServers 配置');
    }

    final existingNames = _servers.map((s) => s.name).toSet();
    final added = <McpServerConfig>[];
    var skipped = 0;

    for (final entry in rawMap.entries) {
      final name = entry.key.toString();
      final value = entry.value;
      if (value is! Map) {
        skipped++;
        continue;
      }
      if (existingNames.contains(name)) {
        skipped++;
        continue;
      }
      final server = McpServerConfig.fromConfigEntry(
        name,
        Map<String, dynamic>.from(value),
        id: _newId('mcp'),
      );
      if (server == null) {
        skipped++;
        continue;
      }
      added.add(server);
      existingNames.add(name);
    }

    if (added.isEmpty) {
      return (imported: 0, skipped: skipped, error: skipped > 0 ? '没有可导入的新配置' : null);
    }
    _servers = [..._servers, ...added];
    await _persist();
    return (imported: added.length, skipped: skipped, error: null);
  }

  Future<ImportedSkill> addSkill({
    required String name,
    required String content,
  }) async {
    final skill = ImportedSkill(
      id: _newId('skill'),
      name: name.trim().isEmpty ? '未命名 Skill' : name.trim(),
      content: content,
      importedAt: DateTime.now(),
    );
    _skills = [..._skills, skill];
    await _persist();
    return skill;
  }

  Future<void> updateSkill(ImportedSkill skill) async {
    _skills = _skills.map((s) => s.id == skill.id ? skill : s).toList();
    await _persist();
  }

  Future<void> removeSkill(String id) async {
    _skills = _skills.where((s) => s.id != id).toList();
    await _persist();
  }

  Future<void> toggleSkill(String id, bool enabled) async {
    _skills =
        _skills.map((s) => s.id == id ? s.copyWith(enabled: enabled) : s).toList();
    await _persist();
  }
}
