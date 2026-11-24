import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/mcp_config.dart';
import 'tool_policy.dart';

/// 远程 MCP 工具
class _RemoteTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const _RemoteTool({
    required this.name,
    this.description = '',
    this.inputSchema = const {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  });
}

class _ToolRef {
  final String serverId;
  final String toolName;

  const _ToolRef(this.serverId, this.toolName);
}

/// 第三方 MCP 管理器
///
/// 负责连接用户配置的 MCP 服务器，把远端工具转换成 OpenAI function 定义，
/// 并在 Agent 调用时转发到对应服务器。
class ExternalMcpManager extends ChangeNotifier {
  ExternalMcpManager._();

  static final ExternalMcpManager instance = ExternalMcpManager._();

  /// 暴露给模型的工具名前缀，避免与内置工具冲突
  static const toolPrefix = 'mcp__';

  final Map<String, _McpSession> _sessions = {};
  final Map<String, _RemoteTool> _tools = {};
  final Map<String, _ToolRef> _refs = {};
  final Map<String, String> _errors = {};
  final Map<String, String> _names = {};
  final Map<String, List<String>> _logs = {};
  final Map<String, int> _restarts = {};

  String _signature = '';
  bool _connecting = false;

  Map<String, String> get errors => Map.unmodifiable(_errors);

  bool get hasServers => _sessions.isNotEmpty;

  /// 已连接的服务器数量
  int get connectedCount => _sessions.length;

  bool isConnected(String serverId) => _sessions.containsKey(serverId);

  /// 各服务器当前暴露的工具数量
  Map<String, int> get toolCounts {
    final counts = <String, int>{};
    for (final ref in _refs.values) {
      counts[ref.serverId] = (counts[ref.serverId] ?? 0) + 1;
    }
    return counts;
  }

  /// 某服务器最近日志（最多 200 行）
  List<String> logsFor(String serverId) =>
      List.unmodifiable(_logs[serverId] ?? const []);

  void _log(String serverId, String line) {
    if (line.trim().isEmpty) return;
    final list = _logs.putIfAbsent(serverId, () => []);
    list.add(line);
    if (list.length > 200) list.removeAt(0);
  }

  /// 重启单个服务器（不影响其他连接）
  Future<void> restartServer(McpServerConfig server) async {
    if (!server.enabled) return;
    _restarts.remove(server.id);
    await _removeServer(server.id);
    _errors.remove(server.id);
    _logs.remove(server.id);
    notifyListeners();
    await _connectServer(server);
  }

  /// 进程崩溃：标记失败并按次数自动重启（最多 2 次）
  Future<void> _handleCrash(McpServerConfig server, String message) async {
    if (!server.enabled) return;
    _errors[server.id] = message;
    _log(server.id, message);
    await _removeServer(server.id);
    notifyListeners();
    final attempts = _restarts[server.id] ?? 0;
    if (attempts >= 2) {
      _log(server.id, '自动重启次数已达上限，已停止重试');
      notifyListeners();
      return;
    }
    _restarts[server.id] = attempts + 1;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!server.enabled) return;
    _errors.remove(server.id);
    _log(server.id, '自动重启（第 ${attempts + 1} 次）');
    await _connectServer(server);
    notifyListeners();
  }

  /// 是否暴露了指定名称的第三方工具
  bool hasTool(String name) => _tools.containsKey(name);

  /// OpenAI function 工具定义
  List<Map<String, dynamic>> get definitions {
    return _tools.entries
        .map((entry) {
          final tool = entry.value;
          return {
            'type': 'function',
            'function': {
              'name': entry.key,
              'description': tool.description,
              'parameters': tool.inputSchema,
            },
          };
        })
        .toList(growable: false);
  }

  /// 按当前配置连接 / 刷新 MCP 服务器
  Future<void> configure(List<McpServerConfig> servers) async {
    final enabled = servers.where((s) => s.enabled).toList();
    final signature = enabled
        .map(
          (s) =>
              '${s.id}:${s.transport}:${s.url}:${s.command}:${s.args.join(',')}:${s.headers.length}',
        )
        .join('|');

    if (signature == _signature) return;
    if (_connecting) return;
    _connecting = true;
    try {
      await _apply(enabled, signature);
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// 忽略缓存强制重新连接（设置页「测试连接」）
  Future<void> refresh(List<McpServerConfig> servers) async {
    _signature = '';
    await configure(servers);
  }

  Future<void> _apply(List<McpServerConfig> servers, String signature) async {
    final keepIds = servers.map((s) => s.id).toSet();

    // 关闭已删除 / 已停用的服务器
    for (final id in _sessions.keys.toList()) {
      if (!keepIds.contains(id)) {
        await _removeServer(id);
      }
    }
    _errors.clear();

    await Future.wait(servers.map(_connectServer));

    _signature = signature;
  }

  /// 连接单个服务器并注册其工具
  Future<void> _connectServer(McpServerConfig server) async {
    if (_sessions.containsKey(server.id)) return;
    try {
      final session = _createSession(server);
      await session.initialize().timeout(const Duration(seconds: 25));
      final tools = await session.listTools().timeout(
        const Duration(seconds: 25),
      );
      _sessions[server.id] = session;
      _errors.remove(server.id);
      _restarts.remove(server.id);
      _log(server.id, '已连接，发现 ${tools.length} 个工具');
      for (final tool in tools) {
        final exposed = _exposedName(server.id, tool.name);
        _tools[exposed] = _RemoteTool(
          name: tool.name,
          description:
              '[${server.name}] ${tool.description.isEmpty ? tool.name : tool.description}',
          inputSchema: tool.inputSchema,
        );
        _refs[exposed] = _ToolRef(server.id, tool.name);
        _names[exposed] = server.name;
      }
    } catch (e) {
      final message = _friendlyError(e);
      _errors[server.id] = message;
      _log(server.id, '连接失败：$message');
    }
  }

  Future<void> _removeServer(String id) async {
    final session = _sessions.remove(id);
    await session?.close();
    final prefix = '$toolPrefix${_safe(id, 14)}__';
    for (final key in _tools.keys.where((k) => k.startsWith(prefix)).toList()) {
      _tools.remove(key);
      _refs.remove(key);
      _names.remove(key);
    }
  }

  _McpSession _createSession(McpServerConfig server) {
    switch (server.transport) {
      case 'stdio':
        return _StdioMcpSession(
          server,
          onLog: (line) => _log(server.id, line),
          onCrash: (message) => _handleCrash(server, message),
        );
      case 'sse':
        return _SseMcpSession(server);
      default:
        return _HttpMcpSession(server);
    }
  }

  String _exposedName(String serverId, String toolName) {
    final sid = _safe(serverId, 14);
    final tn = _safe(toolName, 40);
    var name = '$toolPrefix${sid}__$tn';
    if (name.length > 64) name = name.substring(0, 64);
    var unique = name;
    var index = 1;
    while (_tools.containsKey(unique) || _refs.containsKey(unique)) {
      final suffix = '_$index';
      unique = name.length + suffix.length > 64
          ? name.substring(0, 64 - suffix.length) + suffix
          : name + suffix;
      index++;
    }
    return unique;
  }

  String _safe(String value, int maxLength) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.length > maxLength
        ? cleaned.substring(0, maxLength)
        : cleaned;
  }

  /// 执行第三方 MCP 工具
  Future<String> execute(String name, Map<String, dynamic> args) async {
    final ref = _refs[name];
    if (ref == null) return '错误：未知 MCP 工具 $name';
    final session = _sessions[ref.serverId];
    if (session == null) return '错误：MCP 服务器未连接';
    try {
      final result = await session
          .callTool(ref.toolName, args)
          .timeout(const Duration(seconds: 120));
      return ToolPolicy.truncate(_flattenResult(result));
    } catch (e) {
      final server = _names[name] ?? ref.serverId;
      return '错误：第三方 MCP「$server」调用失败：${_friendlyError(e)}';
    }
  }

  String _flattenResult(Map<String, dynamic> result) {
    final buffer = StringBuffer();
    if (result['isError'] == true) buffer.writeln('工具返回错误：');
    final content = result['content'];
    if (content is List) {
      for (final item in content) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        if (type == 'text') {
          buffer.writeln(item['text'] ?? '');
        } else if (type == 'image') {
          buffer.writeln('[图片 ${item['mimeType'] ?? ''}]');
        } else if (type == 'resource') {
          buffer.writeln(jsonEncode(item['resource']));
        } else {
          buffer.writeln(jsonEncode(item));
        }
      }
    }
    final structured = result['structuredContent'];
    if (structured != null) {
      buffer.writeln(jsonEncode(structured));
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? '（MCP 工具无返回内容）' : text;
  }

  String _friendlyError(Object error) {
    if (error is TimeoutException) return '连接超时';
    if (error is _McpUnsupported) return error.message;
    return error.toString();
  }

  /// 关闭全部连接（单例常驻，正常流程不会调用）
  Future<void> shutdown() async {
    for (final session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
    _tools.clear();
    _refs.clear();
    _signature = '';
  }
}

class _McpUnsupported implements Exception {
  final String message;
  const _McpUnsupported(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// 会话抽象
// ---------------------------------------------------------------------------

abstract class _McpSession {
  Future<void> initialize();
  Future<List<_RemoteTool>> listTools();
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  );
  Future<void> close();
}

List<_RemoteTool> _toolsFromResponse(Map<String, dynamic> response) {
  if (response['error'] != null) {
    throw Exception('MCP 错误：${jsonEncode(response['error'])}');
  }
  final result = response['result'];
  if (result is! Map) return const [];
  final tools = result['tools'];
  if (tools is! List) return const [];
  return tools
      .whereType<Map>()
      .map((raw) {
        final schema = raw['inputSchema'];
        return _RemoteTool(
          name: (raw['name'] ?? '').toString(),
          description: (raw['description'] ?? '').toString(),
          inputSchema: schema is Map
              ? Map<String, dynamic>.from(schema)
              : const {'type': 'object', 'properties': <String, dynamic>{}},
        );
      })
      .where((t) => t.name.isNotEmpty)
      .toList();
}

Map<String, dynamic> _callFromResponse(Map<String, dynamic> response) {
  if (response['error'] != null) {
    throw Exception('MCP 错误：${jsonEncode(response['error'])}');
  }
  final result = response['result'];
  if (result is Map) return Map<String, dynamic>.from(result);
  return {'content': <Map<String, dynamic>>[]};
}

Map<String, dynamic> _initializePayload(int id) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'initialize',
  'params': {
    'protocolVersion': '2025-03-26',
    'capabilities': <String, dynamic>{},
    'clientInfo': {'name': 'SLIPE', 'version': '1.0.0'},
  },
};

const _initializedNotification = {
  'jsonrpc': '2.0',
  'method': 'notifications/initialized',
};

// ---------------------------------------------------------------------------
// Streamable HTTP
// ---------------------------------------------------------------------------

class _HttpMcpSession implements _McpSession {
  _HttpMcpSession(this.config);

  final McpServerConfig config;
  final http.Client _client = http.Client();
  String? _sessionId;
  int _nextId = 1;

  Uri get _uri => Uri.parse(config.url);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    ...config.headers,
    if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
  };

  @override
  Future<void> initialize() async {
    if (config.url.isEmpty) {
      throw const _McpUnsupported('MCP 地址为空');
    }
    final id = _nextId++;
    final response = await _post(_initializePayload(id), expectId: id);
    if (response['result'] == null && response['error'] != null) {
      throw Exception('MCP 初始化失败：${jsonEncode(response['error'])}');
    }
    await _post(_initializedNotification, expectResponse: false);
  }

  @override
  Future<List<_RemoteTool>> listTools() async {
    final id = _nextId++;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/list',
      'params': <String, dynamic>{},
    }, expectId: id);
    return _toolsFromResponse(response);
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final id = _nextId++;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }, expectId: id);
    return _callFromResponse(response);
  }

  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> payload, {
    int? expectId,
    bool expectResponse = true,
  }) async {
    http.Response response;
    try {
      response = await _client
          .post(_uri, headers: _headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 40));
    } catch (e) {
      throw Exception('连接失败：$e');
    }
    _sessionId = response.headers['mcp-session-id'] ?? _sessionId;
    if (!expectResponse || response.statusCode == 202) return {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}：${_short(response.body)}');
    }
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      final parsed = _parseSse(response.body, expectId);
      if (parsed == null) throw Exception('MCP 未返回有效响应');
      return parsed;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw Exception('MCP 响应格式异常');
  }

  Map<String, dynamic>? _parseSse(String body, int? expectId) {
    Map<String, dynamic>? fallback;
    for (final line in const LineSplitter().convert(body)) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        if (expectId != null && map['id'] == expectId) return map;
        if (map['result'] != null || map['error'] != null) fallback = map;
      } catch (_) {
        // ignore
      }
    }
    return fallback;
  }

  String _short(String text) =>
      text.length > 200 ? text.substring(0, 200) : text;

  @override
  Future<void> close() async {
    try {
      await _client.delete(_uri, headers: _headers);
    } catch (_) {
      // ignore
    }
    _client.close();
  }
}

// ---------------------------------------------------------------------------
// 旧版 HTTP + SSE 传输
// ---------------------------------------------------------------------------

class _SseMcpSession implements _McpSession {
  _SseMcpSession(this.config);

  final McpServerConfig config;
  final http.Client _client = http.Client();
  final Completer<void> _endpointReady = Completer<void>();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<String>? _subscription;
  Uri? _endpoint;
  int _nextId = 1;
  bool _closed = false;

  @override
  Future<void> initialize() async {
    if (config.url.isEmpty) throw const _McpUnsupported('MCP 地址为空');
    await _connect();
    final id = _nextId++;
    final response = await _request(_initializePayload(id), id);
    if (response['result'] == null && response['error'] != null) {
      throw Exception('MCP 初始化失败：${jsonEncode(response['error'])}');
    }
    await _notify(_initializedNotification);
  }

  Future<void> _connect() async {
    final request = http.Request('GET', Uri.parse(config.url))
      ..headers.addAll({'Accept': 'text/event-stream', ...config.headers});
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('SSE 连接失败：HTTP ${response.statusCode}');
    }
    String event = '';
    final data = StringBuffer();
    _subscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('event:')) {
              event = line.substring(6).trim();
              return;
            }
            if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.write('\n');
              data.write(line.substring(5).trimLeft());
              return;
            }
            if (line.isEmpty) {
              _dispatch(event, data.toString());
              event = '';
              data.clear();
            }
          },
          onError: _failAll,
          onDone: _failAll,
          cancelOnError: false,
        );
    await _endpointReady.future.timeout(const Duration(seconds: 30));
  }

  void _dispatch(String event, String payload) {
    if (event == 'endpoint') {
      _endpoint = Uri.parse(config.url).resolve(payload);
      if (!_endpointReady.isCompleted) _endpointReady.complete();
      return;
    }
    if (payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final id = map['id'];
      if (id is num) {
        _pending.remove(id.toInt())?.complete(map);
      }
    } catch (_) {
      // ignore
    }
  }

  void _failAll([Object? error]) {
    if (_closed) return;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error ?? Exception('SSE 连接已断开'));
      }
    }
    _pending.clear();
    if (!_endpointReady.isCompleted) {
      _endpointReady.completeError(error ?? Exception('SSE 连接已断开'));
    }
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> payload,
    int id,
  ) async {
    final endpoint = _endpoint;
    if (endpoint == null) throw Exception('SSE endpoint 未就绪');
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final response = await _client
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json', ...config.headers},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _pending.remove(id);
      throw Exception('HTTP ${response.statusCode}：${_short(response.body)}');
    }
    return completer.future.timeout(const Duration(seconds: 60));
  }

  Future<void> _notify(Map<String, dynamic> payload) async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    await _client
        .post(
          endpoint,
          headers: {'Content-Type': 'application/json', ...config.headers},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));
  }

  @override
  Future<List<_RemoteTool>> listTools() async {
    final id = _nextId++;
    final response = await _request({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/list',
      'params': <String, dynamic>{},
    }, id);
    return _toolsFromResponse(response);
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final id = _nextId++;
    final response = await _request({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }, id);
    return _callFromResponse(response);
  }

  String _short(String text) =>
      text.length > 200 ? text.substring(0, 200) : text;

  @override
  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    _client.close();
  }
}

// ---------------------------------------------------------------------------
// stdio（仅桌面端）
// ---------------------------------------------------------------------------

class _StdioMcpSession implements _McpSession {
  _StdioMcpSession(this.config, {this.onLog, this.onCrash});

  final McpServerConfig config;
  final void Function(String line)? onLog;
  final void Function(String message)? onCrash;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _nextId = 1;
  bool _closed = false;

  bool get _supported {
    if (kIsWeb) return false;
    return !(Platform.isAndroid || Platform.isIOS);
  }

  @override
  Future<void> initialize() async {
    if (!_supported) {
      throw const _McpUnsupported('移动端暂不支持 stdio MCP，请使用 HTTP / SSE 服务器');
    }
    if (config.command.isEmpty) {
      throw const _McpUnsupported('stdio MCP 缺少 command');
    }
    final env = <String, String>{...Platform.environment, ...config.env};
    _process = await Process.start(
      config.command,
      config.args,
      environment: env,
      runInShell: true,
    );
    _stdout = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderr = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          debugPrint('[MCP stderr] $line');
          onLog?.call(line);
        });
    _process!.exitCode.then((code) {
      if (_closed) return;
      _failAll(Exception('MCP 进程已退出'));
      onLog?.call('进程已退出（code=$code）');
      onCrash?.call('进程异常退出（code=$code）');
    });

    final id = _nextId++;
    final response = await _request(_initializePayload(id), id);
    if (response['result'] == null && response['error'] != null) {
      throw Exception('MCP 初始化失败：${jsonEncode(response['error'])}');
    }
    await _notify(_initializedNotification);
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final id = map['id'];
      if (id is num) {
        _pending.remove(id.toInt())?.complete(map);
      }
    } catch (_) {
      debugPrint('[MCP stdout] $line');
    }
  }

  void _failAll(Object error) {
    if (_closed) return;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> payload,
    int id,
  ) async {
    final process = _process;
    if (process == null) throw Exception('MCP 进程未启动');
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    process.stdin.writeln(jsonEncode(payload));
    return completer.future.timeout(const Duration(seconds: 60));
  }

  Future<void> _notify(Map<String, dynamic> payload) async {
    _process?.stdin.writeln(jsonEncode(payload));
  }

  @override
  Future<List<_RemoteTool>> listTools() async {
    final id = _nextId++;
    final response = await _request({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/list',
      'params': <String, dynamic>{},
    }, id);
    return _toolsFromResponse(response);
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final id = _nextId++;
    final response = await _request({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }, id);
    return _callFromResponse(response);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _process?.kill();
    _process = null;
  }
}
