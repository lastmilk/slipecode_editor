import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/lua_plugin.dart';
import '../models/plugin.dart';
import 'lsp/lsp_server_store.dart';
import 'lua/lua_runtime_service.dart';

/// 插件管理（仅桌面端）
///
/// 目录结构：
/// ```
/// <应用支持目录>/plugins/
///   registry.json          # 安装记录（enabled / 来源 / 时间）
///   <plugin-id>/plugin.json
/// ```
/// 插件与 Payload 无关：插件只影响 IDE 体验（LSP / 命令 / 片段 / 主题）。
class PluginService extends ChangeNotifier {
  PluginService._();

  static final PluginService instance = PluginService._();

  static const _registryFile = 'registry.json';

  final List<InstalledPlugin> _plugins = [];
  Directory? _root;
  bool _loaded = false;

  List<InstalledPlugin> get plugins => List.unmodifiable(_plugins);

  List<InstalledPlugin> get enabledPlugins =>
      _plugins.where((plugin) => plugin.enabled).toList();

  bool get isLoaded => _loaded;

  Future<Directory> _ensureRoot() async {
    final existing = _root;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'plugins'));
    await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  /// 启动 / 打开设置页时调用（幂等）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final root = await _ensureRoot();
      final registry = File(p.join(root.path, _registryFile));
      if (!await registry.exists()) {
        // 首次启动：扫描目录，兼容手动放入的插件
        await _scanDirectory(root);
        return;
      }
      final raw = jsonDecode(await registry.readAsString());
      if (raw is! List) return;
      for (final item in raw) {
        if (item is! Map) continue;
        final plugin = InstalledPlugin.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (plugin.manifest.id.isEmpty) continue;
        _plugins.add(plugin);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('读取插件注册表失败：$e');
    }
  }

  Future<void> _scanDirectory(Directory root) async {
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      try {
        final jsonFile = File(p.join(entry.path, 'plugin.json'));
        final xmlFile = File(p.join(entry.path, 'metadata.xml'));
        if (await xmlFile.exists()) {
          final lua = LuaPluginManifest.fromXml(await xmlFile.readAsString());
          final hash = await Isolate.run(
            () => hashLuaPluginDirectory(entry.path),
          );
          _plugins.add(_luaInstalledPlugin(lua, entry.path, hash));
          continue;
        }
        if (!await jsonFile.exists()) continue;
        final manifest = PluginManifest.fromJson(
          jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>,
        );
        if (manifest.id.isEmpty) continue;
        _plugins.add(
          InstalledPlugin(
            manifest: manifest,
            directory: entry.path,
            installedAt: (await jsonFile.lastModified()).millisecondsSinceEpoch,
          ),
        );
      } catch (e) {
        debugPrint('跳过无效插件 ${entry.path}：$e');
      }
    }
    await _saveRegistry();
    notifyListeners();
  }

  Future<void> _saveRegistry() async {
    final root = await _ensureRoot();
    final file = File(p.join(root.path, _registryFile));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([for (final plugin in _plugins) plugin.toJson()]),
    );
  }

  /// 从插件清单安装（市场下载 / 本地文件安装共用）
  ///
  /// 返回安装后的插件；`directory` 里的 `plugin.json` 会被写入。
  Future<InstalledPlugin> install({
    required PluginManifest manifest,
    String source = 'local',
    Map<String, dynamic> extraFiles = const {},
  }) async {
    if (manifest.id.isEmpty) {
      throw const PluginException('插件清单缺少 id');
    }
    await ensureLoaded();
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, manifest.id));
    await dir.create(recursive: true);
    final manifestFile = File(p.join(dir.path, 'plugin.json'));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
    // 额外的声明文件（如 README、片段文件）一并落盘，便于审计
    for (final entry in extraFiles.entries) {
      final target = File(p.join(dir.path, entry.key));
      await target.parent.create(recursive: true);
      await target.writeAsString(entry.value.toString());
    }

    final existingIndex = _plugins.indexWhere(
      (item) => item.manifest.id == manifest.id,
    );
    final plugin = InstalledPlugin(
      manifest: manifest,
      directory: dir.path,
      enabled: true,
      installedAt: DateTime.now().millisecondsSinceEpoch,
      source: source,
    );
    if (existingIndex >= 0) {
      _plugins[existingIndex] = plugin;
    } else {
      _plugins.add(plugin);
    }
    await _saveRegistry();
    notifyListeners();
    return plugin;
  }

  /// 从本地目录安装，优先识别 Lua 的 metadata.xml，其次兼容 plugin.json。
  Future<InstalledPlugin> installFromDirectory(String path) async {
    final xmlFile = File(p.join(path, 'metadata.xml'));
    if (await xmlFile.exists()) return installLuaFromDirectory(path);
    final manifestFile = File(p.join(path, 'plugin.json'));
    if (!await manifestFile.exists()) {
      throw const PluginException('所选目录中没有 metadata.xml 或 plugin.json');
    }
    final manifest = PluginManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
    );
    return install(manifest: manifest);
  }

  /// 校验并完整复制 Lua 插件，避免只登记清单却缺失可执行源码。
  Future<InstalledPlugin> installLuaFromDirectory(String path) async {
    final source = Directory(path);
    if (!await source.exists()) {
      throw const PluginException('插件目录不存在');
    }
    final xmlFile = File(p.join(source.path, 'metadata.xml'));
    if (!await xmlFile.exists()) {
      throw const PluginException('Lua 插件目录中没有 metadata.xml');
    }
    final lua = LuaPluginManifest.fromXml(await xmlFile.readAsString());
    if (!await File(p.join(source.path, lua.entry)).exists()) {
      throw const PluginException('metadata.xml 声明的 entry 文件不存在');
    }
    if (lua.config.isNotEmpty &&
        !await File(p.join(source.path, lua.config)).exists()) {
      throw const PluginException('metadata.xml 声明的 config 文件不存在');
    }

    await ensureLoaded();
    final root = await _ensureRoot();
    final target = Directory(p.join(root.path, lua.id));
    final staging = Directory(p.join(root.path, '.${lua.id}.$pid.lua-tmp'));
    final backup = Directory(p.join(root.path, '.${lua.id}.$pid.lua-backup'));
    if (await staging.exists()) await staging.delete(recursive: true);
    if (await backup.exists()) await backup.delete(recursive: true);
    await staging.create(recursive: true);

    _LuaCopyResult copied;
    try {
      copied = await Isolate.run(
        () => _copyAndHashLuaPlugin(source.path, staging.path),
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }

    var movedOld = false;
    try {
      if (await target.exists()) {
        await target.rename(backup.path);
        movedOld = true;
      }
      await staging.rename(target.path);
    } catch (_) {
      if (movedOld && await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete(recursive: true);

    var plugin = _luaInstalledPlugin(
      lua,
      target.path,
      copied.contentHash,
      installedAt: copied.installedAt,
    );
    final existingIndex = _plugins.indexWhere(
      (item) => item.manifest.id == lua.id,
    );
    if (existingIndex >= 0) {
      plugin = plugin.copyWith(enabled: _plugins[existingIndex].enabled);
      _plugins[existingIndex] = plugin;
    } else {
      _plugins.add(plugin);
    }
    await _saveRegistry();
    notifyListeners();
    if (plugin.enabled) {
      await LuaRuntimeService.instance.reloadPlugin(plugin);
    }
    return plugin;
  }

  /// 重载前重新读取清单与内容 hash，授权不会沿用到修改后的代码。
  Future<InstalledPlugin?> refreshLuaPlugin(String pluginId) async {
    final index = _plugins.indexWhere((item) => item.manifest.id == pluginId);
    if (index < 0 || !_plugins[index].isLua) return null;
    final current = _plugins[index];
    try {
      final xml = File(p.join(current.directory, 'metadata.xml'));
      final lua = LuaPluginManifest.fromXml(await xml.readAsString());
      final hash = await Isolate.run(
        () => hashLuaPluginDirectory(current.directory),
      );
      final refreshed = InstalledPlugin(
        manifest: current.manifest,
        directory: current.directory,
        enabled: current.enabled,
        installedAt: current.installedAt,
        source: current.source,
        luaManifest: lua,
        contentHash: hash,
      );
      _plugins[index] = refreshed;
      await _saveRegistry();
      notifyListeners();
      if (refreshed.enabled) {
        await LuaRuntimeService.instance.reloadPlugin(refreshed);
      } else {
        await LuaRuntimeService.instance.unloadPlugin(pluginId);
      }
      return refreshed;
    } catch (e) {
      debugPrint('刷新 Lua 插件 $pluginId 失败：$e');
      return null;
    }
  }

  /// 从 JSON 文本安装（粘贴清单 / 从社区复制）
  Future<InstalledPlugin> installFromJsonText(String text) async {
    final data = jsonDecode(text);
    if (data is! Map) throw const PluginException('插件清单必须是 JSON 对象');
    return install(
      manifest: PluginManifest.fromJson(Map<String, dynamic>.from(data)),
    );
  }

  /// 启用 / 禁用（立即持久化）
  Future<void> setEnabled(String pluginId, bool enabled) async {
    final index = _plugins.indexWhere((item) => item.manifest.id == pluginId);
    if (index < 0) return;
    final plugin = _plugins[index].copyWith(enabled: enabled);
    _plugins[index] = plugin;
    await _saveRegistry();
    notifyListeners();
    if (!plugin.isLua) return;
    if (enabled) {
      await LuaRuntimeService.instance.loadPlugin(plugin);
    } else {
      await LuaRuntimeService.instance.unloadPlugin(pluginId);
    }
  }

  /// 卸载：删除目录与注册记录
  Future<void> uninstall(String pluginId) async {
    final index = _plugins.indexWhere((item) => item.manifest.id == pluginId);
    if (index < 0) return;
    final plugin = _plugins[index];
    if (plugin.isLua) {
      await LuaRuntimeService.instance.unloadPlugin(pluginId);
    }
    _plugins.removeAt(index);
    try {
      final dir = Directory(plugin.directory);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('删除插件目录失败：$e');
    }
    await _saveRegistry();
    if (plugin.isLua) {
      await LuaRuntimeService.instance.permissions.revoke(pluginId);
    }
    notifyListeners();
  }

  bool isInstalled(String pluginId) =>
      _plugins.any((item) => item.manifest.id == pluginId);

  /// 插件提供的语言服务配置（供 LspManager 启动）
  ///
  /// 命令支持相对插件目录的路径：写 `./bin/server` 时会展开为绝对路径。
  List<LspServerConfig> lspConfigs() {
    final result = <LspServerConfig>[];
    for (final plugin in _plugins) {
      if (!plugin.enabled) continue;
      for (final server in plugin.manifest.contributes.lspServers) {
        if (server.command.trim().isEmpty) continue;
        final command =
            server.command.startsWith('./') || server.command.startsWith('.\\')
            ? p.normalize(p.join(plugin.directory, server.command))
            : server.command;
        result.add(
          LspServerConfig(
            id: 'plugin:${plugin.manifest.id}:${server.languageId}',
            name: '${plugin.manifest.name}（${server.languageId}）',
            command: command,
            args: server.args,
            extensions: server.extensions,
            languageId: server.languageId,
            env: server.env,
            initializationOptions: server.initializationOptions,
            autoStart: server.autoStart,
          ),
        );
      }
    }
    return result;
  }

  /// 已启用插件的代码片段（按语言聚合，供补全使用）
  List<PluginSnippetContribution> snippetsFor(String language) {
    final result = <PluginSnippetContribution>[];
    for (final plugin in _plugins) {
      if (!plugin.enabled) continue;
      for (final snippet in plugin.manifest.contributes.snippets) {
        if (snippet.language == language) result.add(snippet);
      }
    }
    return result;
  }
}

InstalledPlugin _luaInstalledPlugin(
  LuaPluginManifest lua,
  String directory,
  String contentHash, {
  int? installedAt,
}) {
  return InstalledPlugin(
    manifest: PluginManifest(
      id: lua.id,
      name: lua.name,
      version: lua.version,
      publisher: lua.publisher,
      category: 'tools',
      tags: const ['lua'],
      engines: const {'slipe': '>=1.0.0'},
      declaredCapabilities: [for (final item in lua.capabilities) item.name],
    ),
    directory: directory,
    installedAt: installedAt ?? DateTime.now().millisecondsSinceEpoch,
    luaManifest: lua,
    contentHash: contentHash,
  );
}

class _LuaCopyResult {
  const _LuaCopyResult(this.contentHash, this.installedAt);

  final String contentHash;
  final int installedAt;
}

Future<_LuaCopyResult> _copyAndHashLuaPlugin(
  String source,
  String target,
) async {
  final sourceDir = Directory(source);
  await for (final entry in sourceDir.list(
    recursive: true,
    followLinks: false,
  )) {
    final relative = p.relative(entry.path, from: source);
    final destination = p.join(target, relative);
    if (entry is Link) {
      throw const PluginException('Lua 插件目录不允许包含符号链接');
    }
    if (entry is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entry is File) {
      final file = File(destination);
      await file.parent.create(recursive: true);
      await entry.copy(file.path);
    }
  }
  return _LuaCopyResult(
    await hashLuaPluginDirectory(target),
    DateTime.now().millisecondsSinceEpoch,
  );
}

/// 对相对路径和每个文件内容做链式哈希；任何代码变化都会使旧授权失效。
Future<String> hashLuaPluginDirectory(String path) async {
  final files = <File>[];
  await for (final entry in Directory(
    path,
  ).list(recursive: true, followLinks: false)) {
    if (entry is Link) {
      throw const PluginException('Lua 插件目录不允许包含符号链接');
    }
    if (entry is File) files.add(entry);
  }
  files.sort(
    (a, b) => p
        .relative(a.path, from: path)
        .compareTo(p.relative(b.path, from: path)),
  );
  final parts = <String>[];
  for (final file in files) {
    final relative = p.relative(file.path, from: path).replaceAll('\\', '/');
    final digest = sha256.convert(await file.readAsBytes());
    parts.add('$relative:$digest');
  }
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

class PluginException implements Exception {
  const PluginException(this.message);

  final String message;

  @override
  String toString() => message;
}
