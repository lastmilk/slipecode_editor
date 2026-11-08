/// 第三方 MCP 服务器配置（支持手动表单与 Claude Desktop 风格配置文件导入）
class McpServerConfig {
  final String id;
  final String name;

  /// http / sse / stdio
  final String transport;
  final String url;
  final Map<String, String> headers;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  const McpServerConfig({
    required this.id,
    required this.name,
    this.transport = 'http',
    this.url = '',
    this.headers = const {},
    this.command = '',
    this.args = const [],
    this.env = const {},
    this.enabled = true,
  });

  bool get isStdio => transport == 'stdio';

  String get endpointLabel {
    if (isStdio) {
      return [command, ...args].where((e) => e.isNotEmpty).join(' ');
    }
    return url;
  }

  McpServerConfig copyWith({
    String? name,
    String? transport,
    String? url,
    Map<String, String>? headers,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    bool? enabled,
  }) {
    return McpServerConfig(
      id: id,
      name: name ?? this.name,
      transport: transport ?? this.transport,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      command: command ?? this.command,
      args: args ?? this.args,
      env: env ?? this.env,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'transport': transport,
        'url': url,
        'headers': headers,
        'command': command,
        'args': args,
        'env': env,
        'enabled': enabled,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    final rawEnv = json['env'];
    final rawArgs = json['args'];
    return McpServerConfig(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      transport: (json['transport'] ?? 'http').toString(),
      url: (json['url'] ?? '').toString(),
      headers: rawHeaders is Map
          ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      command: (json['command'] ?? '').toString(),
      args: rawArgs is List ? rawArgs.map((e) => e.toString()).toList() : const [],
      env: rawEnv is Map
          ? rawEnv.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      enabled: json['enabled'] != false,
    );
  }

  /// 从 Claude Desktop / Cursor 的 mcpServers 配置项解析
  static McpServerConfig? fromConfigEntry(
    String name,
    Map<String, dynamic> entry, {
    required String id,
  }) {
    final url = (entry['url'] ?? entry['endpoint'] ?? '').toString();
    final command = (entry['command'] ?? '').toString();
    final rawHeaders = entry['headers'];
    final rawEnv = entry['env'];
    final rawArgs = entry['args'];
    String transport = (entry['type'] ?? entry['transport'] ?? '').toString();
    if (transport.isEmpty) {
      transport = url.isNotEmpty ? 'http' : 'stdio';
    }
    if (transport == 'streamable-http' || transport == 'streamableHttp') {
      transport = 'http';
    }
    if (url.isEmpty && command.isEmpty) return null;
    return McpServerConfig(
      id: id,
      name: name,
      transport: transport,
      url: url,
      headers: rawHeaders is Map
          ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      command: command,
      args: rawArgs is List ? rawArgs.map((e) => e.toString()).toList() : const [],
      env: rawEnv is Map
          ? rawEnv.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      enabled: true,
    );
  }
}

/// 用户导入的外源 Skill（Markdown / 文本，追加到系统提示词）
class ImportedSkill {
  final String id;
  final String name;
  final String content;
  final bool enabled;
  final DateTime? importedAt;

  const ImportedSkill({
    required this.id,
    required this.name,
    required this.content,
    this.enabled = true,
    this.importedAt,
  });

  ImportedSkill copyWith({String? name, String? content, bool? enabled}) {
    return ImportedSkill(
      id: id,
      name: name ?? this.name,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
      importedAt: importedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'content': content,
        'enabled': enabled,
        'importedAt': importedAt?.toIso8601String(),
      };

  factory ImportedSkill.fromJson(Map<String, dynamic> json) {
    return ImportedSkill(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      enabled: json['enabled'] != false,
      importedAt: DateTime.tryParse((json['importedAt'] ?? '').toString()),
    );
  }
}
