import 'package:xml/xml.dart';

/// Lua 插件清单（metadata.xml）。
///
/// XML 只声明能力；`editor.modify` 仍需 pluginhook.init 请求并获得用户授权。
class LuaPluginManifest {
  const LuaPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.publisher,
    required this.api,
    required this.entry,
    this.config = '',
    this.capabilities = const [],
  });

  final String id;
  final String name;
  final String version;
  final String publisher;
  final int api;
  final String entry;
  final String config;
  final List<LuaPluginCapability> capabilities;

  static const supportedApi = 1;
  static const editorModify = 'editor.modify';

  bool get requestsEditorModify =>
      capabilities.any((item) => item.name == editorModify);

  String? editorModifyReason() {
    for (final capability in capabilities) {
      if (capability.name == editorModify) return capability.reason;
    }
    return null;
  }

  factory LuaPluginManifest.fromXml(String source) {
    final document = XmlDocument.parse(source);
    final root = document.rootElement;
    if (root.name.local != 'plugin') {
      throw const LuaPluginFormatException('metadata.xml 根节点必须是 plugin');
    }
    String attribute(String name, {String fallback = ''}) =>
        root.getAttribute(name)?.trim() ?? fallback;

    final entryElements = root.findElements('entry');
    if (entryElements.length != 1) {
      throw const LuaPluginFormatException('plugin 必须且只能包含一个 entry');
    }
    final configElements = root.findElements('config');
    if (configElements.length > 1) {
      throw const LuaPluginFormatException('plugin 最多包含一个 config');
    }
    final capabilityElements = root
        .findElements('capabilities')
        .expand((node) => node.findElements('capability'))
        .toList();
    final capabilities = <LuaPluginCapability>[];
    final seen = <String>{};
    for (final node in capabilityElements) {
      final name = node.getAttribute('name')?.trim() ?? '';
      if (!LuaPluginCapability.allowed.contains(name)) {
        throw LuaPluginFormatException('未知插件能力：$name');
      }
      if (!seen.add(name)) {
        throw LuaPluginFormatException('插件能力重复声明：$name');
      }
      final reason = node.getAttribute('reason')?.trim() ?? '';
      if (name == editorModify && reason.isEmpty) {
        throw const LuaPluginFormatException('editor.modify 必须声明 reason');
      }
      capabilities.add(LuaPluginCapability(name: name, reason: reason));
    }

    final manifest = LuaPluginManifest(
      id: attribute('id'),
      name: attribute('name'),
      version: attribute('version'),
      publisher: attribute('publisher'),
      api: int.tryParse(attribute('api')) ?? -1,
      entry: entryElements.single.innerText.trim(),
      config: configElements.isEmpty
          ? ''
          : configElements.single.innerText.trim(),
      capabilities: capabilities,
    );
    manifest.validate();
    return manifest;
  }

  void validate() {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(id)) {
      throw const LuaPluginFormatException('插件 id 只能包含小写字母、数字、点、下划线和连字符');
    }
    if (name.isEmpty) {
      throw const LuaPluginFormatException('插件缺少 name');
    }
    if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(version)) {
      throw const LuaPluginFormatException('插件 version 必须是语义化版本');
    }
    if (api != supportedApi) {
      throw LuaPluginFormatException('插件 API 版本不受支持：$api（当前支持 $supportedApi）');
    }
    _validateLuaPath(entry, 'entry');
    if (config.isNotEmpty) _validateLuaPath(config, 'config');
  }

  static void _validateLuaPath(String path, String field) {
    final segments = path.split('/');
    if (!path.endsWith('.lua') ||
        path.startsWith('/') ||
        path.contains('\\') ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw LuaPluginFormatException('$field 必须是插件目录内的相对 .lua 路径');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'publisher': publisher,
    'api': api,
    'entry': entry,
    'config': config,
    'capabilities': [for (final item in capabilities) item.toJson()],
  };

  factory LuaPluginManifest.fromJson(Map<String, dynamic> json) {
    final manifest = LuaPluginManifest(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      publisher: (json['publisher'] ?? '').toString(),
      api: (json['api'] as num?)?.toInt() ?? -1,
      entry: (json['entry'] ?? '').toString(),
      config: (json['config'] ?? '').toString(),
      capabilities: [
        for (final item in json['capabilities'] as List? ?? const [])
          if (item is Map)
            LuaPluginCapability(
              name: (item['name'] ?? '').toString(),
              reason: (item['reason'] ?? '').toString(),
            ),
      ],
    );
    manifest.validate();
    return manifest;
  }
}

class LuaPluginCapability {
  const LuaPluginCapability({required this.name, this.reason = ''});

  static const allowed = {
    'editor.modify',
    'events',
    'configuration',
    'commands',
  };

  final String name;
  final String reason;

  Map<String, dynamic> toJson() => {'name': name, 'reason': reason};
}

class LuaPluginFormatException implements FormatException {
  const LuaPluginFormatException(this.message);

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  dynamic get source => null;

  @override
  String toString() => message;
}
