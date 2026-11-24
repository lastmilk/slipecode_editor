import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/tool_contract.dart';
import '../models/ai_connector.dart';

/// 第三方 OAuth 连接器的公开适配协议。
///
/// 适配器自行管理授权与安全令牌；注册中心只读取不含密钥的状态快照。
abstract class AiConnector {
  ConnectorDefinition get definition;

  ConnectorAuthSnapshot get snapshot;

  Future<void> authorize();

  Future<void> disconnect();

  Future<void> refresh();

  List<McpTool> tools();
}

/// 连接器注册、启停和 Agent 工具路由中心。
class ConnectorService extends ChangeNotifier {
  static const _storageKey = 'slipe_ai_connectors_v1';
  static const toolPrefix = 'connector__';

  final List<AiConnector> _connectors = [];
  final Map<String, bool> _enabled = {};
  bool _loaded = false;

  List<AiConnector> get connectors => List.unmodifiable(_connectors);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final data = jsonDecode(raw);
        if (data is Map) {
          for (final entry in data.entries) {
            _enabled['${entry.key}'] = entry.value != false;
          }
        }
      } catch (_) {
        _enabled.clear();
      }
    }
    _loaded = true;
    notifyListeners();
  }

  void register(AiConnector connector) {
    if (_connectors.any(
      (item) => item.definition.id == connector.definition.id,
    )) {
      throw ArgumentError('连接器 id 重复：${connector.definition.id}');
    }
    _connectors.add(connector);
    notifyListeners();
  }

  bool isEnabled(String id) => _enabled[id] ?? true;

  ConnectorAuthSnapshot snapshotFor(String id) {
    final connector = _byId(id);
    return connector.snapshot.copyWith(enabled: isEnabled(id));
  }

  Future<void> connect(String id) async {
    await ensureLoaded();
    await _byId(id).authorize();
    notifyListeners();
  }

  Future<void> disconnect(String id) async {
    await ensureLoaded();
    await _byId(id).disconnect();
    notifyListeners();
  }

  Future<void> refresh(String id) async {
    await ensureLoaded();
    await _byId(id).refresh();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await ensureLoaded();
    _byId(id);
    _enabled[id] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_enabled));
    notifyListeners();
  }

  /// 当前允许 Agent 使用的连接器工具。
  List<McpTool> get availableTools {
    return [
      for (final connector in _connectors)
        if (isEnabled(connector.definition.id) &&
            connector.snapshot.isConnected)
          ...connector.tools(),
    ];
  }

  bool isReadOnlyTool(String name) {
    return _connectors.any(
      (connector) => connector.tools().any((tool) => tool.name == name),
    );
  }

  Future<String> execute(String name, Map<String, dynamic> args) async {
    await ensureLoaded();
    for (final connector in _connectors) {
      final matches = connector.tools().where((tool) => tool.name == name);
      if (matches.isEmpty) continue;
      if (!isEnabled(connector.definition.id)) {
        return '错误：连接器「${connector.definition.name}」已禁用';
      }
      if (!connector.snapshot.isConnected) {
        return '错误：连接器「${connector.definition.name}」尚未授权';
      }
      try {
        return await matches.first.execute(args);
      } catch (error) {
        return '错误：连接器调用失败：${safeError(error)}';
      }
    }
    return '错误：未知连接器工具 $name';
  }

  AiConnector _byId(String id) {
    for (final connector in _connectors) {
      if (connector.definition.id == id) return connector;
    }
    throw ArgumentError('未注册连接器：$id');
  }

  /// 展示错误前移除常见令牌形式，避免授权信息进入 UI 或 Agent 输出。
  static String safeError(Object error) {
    return '$error'
        .replaceAll(
          RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+'),
          'Bearer [redacted]',
        )
        .replaceAllMapped(
          RegExp(r'([?&](?:access_)?token=)[^&\s]+'),
          (match) => '${match[1]}[redacted]',
        );
  }
}
