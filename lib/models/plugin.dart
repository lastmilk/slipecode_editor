import 'package:flutter/material.dart';

import 'lua_plugin.dart';

/// 插件清单（plugin.json）
///
/// 插件与 Payload 是两套体系：
/// - Payload 决定项目「怎么构建、产出什么」
/// - 插件决定「IDE 自身的体验」：语言服务（LSP）、主题、命令、代码片段
/// 因此插件清单里不出现任何 payload 字段。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    this.version = '0.0.0',
    this.publisher = '',
    this.description = '',
    this.category = 'other',
    this.icon = '',
    this.homepage = '',
    this.license = '',
    this.tags = const [],
    this.engines = const {},
    this.contributes = const PluginContributions(),
    this.declaredCapabilities = const [],
    this.marketId = '',
  });

  /// 插件唯一标识（小写字母 + 数字 + 连字符）
  final String id;
  final String name;
  final String version;
  final String publisher;
  final String description;

  /// language / theme / tools / other
  final String category;

  /// 图标名（内置 Material 图标映射）或空
  final String icon;
  final String homepage;
  final String license;
  final List<String> tags;

  /// 兼容的编辑器版本约束，如 {"slipe": ">=1.0.0"}
  final Map<String, String> engines;
  final PluginContributions contributes;

  /// 服务端在列表接口里返回的能力摘要（lsp / themes / commands / snippets）
  ///
  /// 本地插件不需要该字段，由 [contributes] 推导。
  final List<String> declaredCapabilities;

  /// 插件市场记录 id（安装接口需要），本地安装的插件为空
  final String marketId;

  factory PluginManifest.fromJson(Map<String, dynamic> json) => PluginManifest(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? json['id'] ?? '').toString(),
    version: (json['version'] ?? '0.0.0').toString(),
    publisher: (json['publisher'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    category: (json['category'] ?? 'other').toString(),
    icon: (json['icon'] ?? '').toString(),
    homepage: (json['homepage'] ?? '').toString(),
    license: (json['license'] ?? '').toString(),
    tags: [
      for (final tag in (json['tags'] as List? ?? const []))
        if (tag is String) tag,
    ],
    engines: {
      for (final entry in (json['engines'] as Map? ?? const {}).entries)
        entry.key.toString(): entry.value.toString(),
    },
    declaredCapabilities: [
      for (final capability in (json['capabilities'] as List? ?? const []))
        if (capability is String) capability,
    ],
    marketId: (json['marketId'] ?? '').toString(),
    contributes: json['contributes'] is Map
        ? PluginContributions.fromJson(
            Map<String, dynamic>.from(json['contributes'] as Map),
          )
        : const PluginContributions(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'publisher': publisher,
    'description': description,
    'category': category,
    'icon': icon,
    'homepage': homepage,
    'license': license,
    'tags': tags,
    'engines': engines,
    'contributes': contributes.toJson(),
  };

  /// 分类的展示名
  String get categoryLabel => switch (category) {
    'language' => '语言支持',
    'theme' => '主题外观',
    'tools' => '开发工具',
    _ => '其它',
  };

  /// 分类图标
  IconData get categoryIcon => switch (category) {
    'language' => Icons.translate,
    'theme' => Icons.palette_outlined,
    'tools' => Icons.handyman_outlined,
    _ => Icons.extension_outlined,
  };

  /// 是否提供了可用能力（语言服务 / 命令 / 代码片段 / 主题）
  bool get hasRuntimeContribution =>
      contributes.lspServers.isNotEmpty ||
      contributes.commands.isNotEmpty ||
      contributes.snippets.isNotEmpty;
}

/// 插件贡献点
class PluginContributions {
  const PluginContributions({
    this.lspServers = const [],
    this.commands = const [],
    this.snippets = const [],
    this.themes = const [],
  });

  /// 语言服务：启用插件后自动为对应扩展名启动 LSP
  final List<PluginLspContribution> lspServers;

  /// 命令：可被命令面板调用的可执行命令
  final List<PluginCommandContribution> commands;

  /// 代码片段：按语言分组的片段
  final List<PluginSnippetContribution> snippets;

  /// 主题：可扩展编辑器配色（当前仅作展示与声明）
  final List<String> themes;

  factory PluginContributions.fromJson(Map<String, dynamic> json) {
    final lspRaw = json['lsp'];
    final lspList = <PluginLspContribution>[];
    if (lspRaw is List) {
      for (final item in lspRaw) {
        if (item is Map) {
          lspList.add(
            PluginLspContribution.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    } else if (lspRaw is Map) {
      lspList.add(
        PluginLspContribution.fromJson(Map<String, dynamic>.from(lspRaw)),
      );
    }
    return PluginContributions(
      lspServers: lspList,
      commands: [
        for (final item in (json['commands'] as List? ?? const []))
          if (item is Map)
            PluginCommandContribution.fromJson(Map<String, dynamic>.from(item)),
      ],
      snippets: [
        for (final item in (json['snippets'] as List? ?? const []))
          if (item is Map)
            PluginSnippetContribution.fromJson(Map<String, dynamic>.from(item)),
      ],
      themes: [
        for (final item in (json['themes'] as List? ?? const []))
          if (item is String) item,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'lsp': [for (final server in lspServers) server.toJson()],
    'commands': [for (final command in commands) command.toJson()],
    'snippets': [for (final snippet in snippets) snippet.toJson()],
    'themes': themes,
  };
}

/// 语言服务贡献
class PluginLspContribution {
  const PluginLspContribution({
    required this.languageId,
    required this.command,
    this.extensions = const [],
    this.args = const [],
    this.env = const {},
    this.initializationOptions,
    this.autoStart = true,
  });

  /// LSP languageId，如 go / rust / python
  final String languageId;

  /// 启动命令（相对插件目录或系统 PATH）
  final String command;

  /// 处理的扩展名（含点号，如 .go）
  final List<String> extensions;
  final List<String> args;
  final Map<String, String> env;
  final Map<String, dynamic>? initializationOptions;
  final bool autoStart;

  factory PluginLspContribution.fromJson(Map<String, dynamic> json) =>
      PluginLspContribution(
        languageId: (json['languageId'] ?? json['language'] ?? '').toString(),
        command: (json['command'] ?? '').toString(),
        extensions: [
          for (final ext in (json['extensions'] as List? ?? const []))
            if (ext is String) ext,
        ],
        args: [
          for (final arg in (json['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
        env: {
          for (final entry in (json['env'] as Map? ?? const {}).entries)
            entry.key.toString(): entry.value.toString(),
        },
        initializationOptions: json['initializationOptions'] is Map
            ? Map<String, dynamic>.from(json['initializationOptions'] as Map)
            : null,
        autoStart: json['autoStart'] != false,
      );

  Map<String, dynamic> toJson() => {
    'languageId': languageId,
    'command': command,
    'extensions': extensions,
    'args': args,
    'env': env,
    if (initializationOptions != null)
      'initializationOptions': initializationOptions,
    'autoStart': autoStart,
  };
}

/// 命令贡献（命令面板可调用）
class PluginCommandContribution {
  const PluginCommandContribution({
    required this.command,
    required this.title,
    this.executable = '',
    this.args = const [],
  });

  final String command;
  final String title;
  final String executable;
  final List<String> args;

  factory PluginCommandContribution.fromJson(Map<String, dynamic> json) =>
      PluginCommandContribution(
        command: (json['command'] ?? '').toString(),
        title: (json['title'] ?? json['command'] ?? '').toString(),
        executable: (json['executable'] ?? '').toString(),
        args: [
          for (final arg in (json['args'] as List? ?? const []))
            if (arg is String) arg,
        ],
      );

  Map<String, dynamic> toJson() => {
    'command': command,
    'title': title,
    'executable': executable,
    'args': args,
  };
}

/// 代码片段贡献
class PluginSnippetContribution {
  const PluginSnippetContribution({
    required this.language,
    required this.prefix,
    required this.body,
    this.description = '',
  });

  final String language;
  final String prefix;
  final List<String> body;
  final String description;

  factory PluginSnippetContribution.fromJson(Map<String, dynamic> json) =>
      PluginSnippetContribution(
        language: (json['language'] ?? '').toString(),
        prefix: (json['prefix'] ?? '').toString(),
        body: [
          for (final line in (json['body'] as List? ?? const []))
            if (line is String) line,
        ],
        description: (json['description'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
    'language': language,
    'prefix': prefix,
    'body': body,
    'description': description,
  };
}

/// 本地已安装插件
class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.directory,
    this.enabled = true,
    this.installedAt = 0,
    this.source = 'local',
    this.luaManifest,
    this.contentHash = '',
  });

  /// 列表展示使用的通用清单；Lua 插件会从 metadata.xml 映射生成。
  final PluginManifest manifest;

  /// 插件所在目录（内含 plugin.json 或 metadata.xml）。
  final String directory;
  final bool enabled;
  final int installedAt;

  /// local（文件安装）/ market（插件市场）
  final String source;

  /// 非空表示这是可执行 Lua 插件。
  final LuaPluginManifest? luaManifest;

  /// 安装时插件内容的 SHA-256，授权随内容变化而失效。
  final String contentHash;

  bool get isLua => luaManifest != null;

  InstalledPlugin copyWith({bool? enabled}) => InstalledPlugin(
    manifest: manifest,
    directory: directory,
    enabled: enabled ?? this.enabled,
    installedAt: installedAt,
    source: source,
    luaManifest: luaManifest,
    contentHash: contentHash,
  );

  Map<String, dynamic> toJson() => {
    'manifest': manifest.toJson(),
    'directory': directory,
    'enabled': enabled,
    'installedAt': installedAt,
    'source': source,
    if (luaManifest != null) 'luaManifest': luaManifest!.toJson(),
    if (contentHash.isNotEmpty) 'contentHash': contentHash,
  };

  factory InstalledPlugin.fromJson(Map<String, dynamic> json) =>
      InstalledPlugin(
        manifest: PluginManifest.fromJson(
          Map<String, dynamic>.from(json['manifest'] as Map? ?? const {}),
        ),
        directory: (json['directory'] ?? '').toString(),
        enabled: json['enabled'] != false,
        installedAt: (json['installedAt'] as num?)?.toInt() ?? 0,
        source: (json['source'] ?? 'local').toString(),
        luaManifest: json['luaManifest'] is Map
            ? LuaPluginManifest.fromJson(
                Map<String, dynamic>.from(json['luaManifest'] as Map),
              )
            : null,
        contentHash: (json['contentHash'] ?? '').toString(),
      );
}
