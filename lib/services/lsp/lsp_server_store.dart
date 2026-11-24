import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 语言服务器配置（`lsp_servers.json`）
class LspServerConfig {
  final String id;
  final String name;
  final String command;
  final List<String> args;
  final List<String> extensions;
  final String languageId;
  final Map<String, String> env;
  final Map<String, dynamic>? initializationOptions;
  final bool autoStart;
  final bool builtin;

  bool enabled;

  LspServerConfig({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    required this.extensions,
    required this.languageId,
    this.env = const {},
    this.initializationOptions,
    this.autoStart = true,
    this.builtin = false,
    this.enabled = true,
  });

  /// 该扩展名是否由本服务处理
  bool handles(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext.isEmpty) return false;
    return extensions.any((item) {
      final normalized = item.startsWith('.') ? item.toLowerCase() : '.$item';
      return normalized == ext;
    });
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
        'args': args,
        'extensions': extensions,
        'languageId': languageId,
        'env': env,
        'initializationOptions': initializationOptions,
        'enabled': enabled,
        'autoStart': autoStart,
      };

  factory LspServerConfig.fromJson(Map<String, dynamic> json) => LspServerConfig(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        command: (json['command'] as String?) ?? '',
        args: [
          for (final arg in (json['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
        extensions: [
          for (final ext in (json['extensions'] as List? ?? const []))
            if (ext is String) ext,
        ],
        languageId: (json['languageId'] as String?) ?? 'plaintext',
        env: {
          for (final entry in (json['env'] as Map? ?? const {}).entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
        },
        initializationOptions:
            (json['initializationOptions'] as Map?)?.cast<String, dynamic>(),
        enabled: json['enabled'] != false,
        autoStart: json['autoStart'] != false,
      );

  LspServerConfig copyWith({
    String? command,
    List<String>? args,
    List<String>? extensions,
    bool? enabled,
  }) {
    return LspServerConfig(
      id: id,
      name: name,
      command: command ?? this.command,
      args: args ?? this.args,
      extensions: extensions ?? this.extensions,
      languageId: languageId,
      env: env,
      initializationOptions: initializationOptions,
      autoStart: autoStart,
      builtin: builtin,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// 语言服务器配置存储
///
/// - 内置 Dart 条目（只读展示，命令由工具链自动发现覆盖）
/// - 自定义条目可增删改，落盘到 `<appSupport>/lsp_servers.json`
class LspServerStore {
  LspServerStore._();

  static final LspServerStore instance = LspServerStore._();

  static const String dartServerId = 'dart';

  final List<LspServerConfig> _custom = [];
  File? _file;
  bool _loaded = false;

  List<LspServerConfig> get servers => [
        dartConfig,
        ..._custom,
      ];

  List<LspServerConfig> get customServers => List.unmodifiable(_custom);

  /// 内置 Dart 条目（命令在发现阶段被实际可执行文件覆盖）
  LspServerConfig get dartConfig => LspServerConfig(
        id: dartServerId,
        name: 'Dart / Flutter',
        command: 'dart',
        args: const ['language-server', '--protocol=lsp'],
        extensions: const ['.dart'],
        languageId: 'dart',
        initializationOptions: const {
          'onlyAnalyzeProjectsWithOpenFiles': false,
          'suggestFromUnimportedLibraries': true,
          'closingLabels': true,
        },
        builtin: true,
      );

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'lsp_servers.json'));
      _file = file;
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final list = raw['servers'];
      if (list is! List) return;
      _custom
        ..clear()
        ..addAll([
          for (final item in list)
            if (item is Map)
              LspServerConfig.fromJson(item.cast<String, dynamic>()),
        ]);
    } catch (e) {
      debugPrint('读取语言服务配置失败：$e');
    }
  }

  Future<void> save() async {
    try {
      final file = _file ??
          File(p.join(
            (await getApplicationSupportDirectory()).path,
            'lsp_servers.json',
          ));
      _file = file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'servers': [for (final server in _custom) server.toJson()],
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('保存语言服务配置失败：$e');
    }
  }

  Future<void> upsert(LspServerConfig config) async {
    await ensureLoaded();
    final index = _custom.indexWhere((item) => item.id == config.id);
    if (index == -1) {
      _custom.add(config);
    } else {
      _custom[index] = config;
    }
    await save();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _custom.removeWhere((item) => item.id == id);
    await save();
  }

  /// 按扩展名查找启用的服务（自定义优先于内置）
  LspServerConfig? serverFor(String path) {
    for (final server in _custom) {
      if (server.enabled && server.handles(path)) return server;
    }
    final dart = dartConfig;
    return dart.handles(path) ? dart : null;
  }

  bool get anyEnabled => _custom.any((item) => item.enabled) || dartConfig.enabled;

  void setBuiltinEnabled(bool value) {
    dartConfig.enabled = value;
  }

  /// 自定义服务启用开关（立即落盘）
  Future<void> setCustomEnabled(String id, bool value) async {
    await ensureLoaded();
    final index = _custom.indexWhere((item) => item.id == id);
    if (index == -1) return;
    _custom[index].enabled = value;
    await save();
  }
}
