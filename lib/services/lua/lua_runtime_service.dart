import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slipe_lua/slipe_lua.dart';

import '../../models/plugin.dart';
import '../../providers/lsp_provider.dart';
import '../../providers/settings_provider.dart';
import '../app_globals.dart';
import '../command_registry.dart';
import '../desktop_prefs_service.dart';
import '../plugin_service.dart';
import 'lua_config_service.dart';
import 'lua_permission_service.dart';
import 'plugin_event_bus.dart';
import 'plugin_service_registry.dart';

/// 应用级 Lua 运行时：每个插件独立 VM，注册表只保存当前可用代际。
class LuaRuntimeService extends ChangeNotifier {
  LuaRuntimeService._()
    : registry = PluginServiceRegistry(
        isEditorModifyGranted: _isEditorModifyGranted,
      ),
      events = PluginEventBus(
        hasCapability: (pluginId, capability) =>
            _pluginDeclares(pluginId, capability),
        isEditorModifyGranted: _isEditorModifyGranted,
        onError: (hook, error) => _recordError(hook.pluginId, error),
      ),
      config = LuaConfigService(
        hasConfigurationCapability: (pluginId) =>
            _pluginDeclares(pluginId, 'configuration'),
      ) {
    registry.attachLuaBackend(_call);
    events
      ..setExecutor(_executeEvent)
      ..setSyncExecutor(_executeSyncEvent);
  }

  static final LuaRuntimeService instance = LuaRuntimeService._();

  final PluginServiceRegistry registry;
  final PluginEventBus events;
  final LuaConfigService config;
  final LuaPermissionService permissions = LuaPermissionService.instance;

  final Map<String, SlipeLuaVm> _vms = {};
  final Map<String, String> _errors = {};
  final Map<String, Object?> _effectiveApp = {};
  final Map<String, Object?> _effectiveDesktop = {};
  List<DesktopCommand> _luaCommands = const [];
  LuaConfigContribution? _userConfig;
  SettingsProvider? _settings;
  LspProvider? _lsp;
  bool _started = false;
  Future<void> _queue = Future.value();

  Map<String, String> get errors => Map.unmodifiable(_errors);
  String? errorFor(String pluginId) => _errors[pluginId];
  List<DesktopCommand> get luaCommands => List.unmodifiable(_luaCommands);
  bool isVmLoaded(String pluginId) => _vms.containsKey(pluginId);

  static bool _pluginDeclares(String pluginId, String capability) {
    for (final plugin in PluginService.instance.plugins) {
      if (plugin.manifest.id == pluginId && plugin.enabled) {
        return plugin.luaManifest?.capabilities.any(
              (item) => item.name == capability,
            ) ??
            false;
      }
    }
    return false;
  }

  static bool _isEditorModifyGranted(String pluginId) {
    for (final plugin in PluginService.instance.plugins) {
      if (plugin.manifest.id == pluginId && plugin.enabled) {
        return instance.permissions.isGranted(plugin);
      }
    }
    return false;
  }

  static void _recordError(String pluginId, Object error) {
    instance._errors[pluginId] = error.toString();
    instance.notifyListeners();
  }

  void attachSettings(SettingsProvider settings) {
    _settings = settings;
    settings.applyLuaOverrides(_effectiveApp);
    DesktopPrefsService.instance.applyLuaOverrides(_effectiveDesktop);
    config.addListener(_applyConfig);
    _applyConfig();
  }

  void attachLsp(LspProvider lsp) {
    _lsp = lsp;
    config.addListener(_applyLsp);
    _applyLsp();
  }

  void _applyConfig() {
    _effectiveApp
      ..clear()
      ..addEntries(
        config.settings.entries
            .where(
              (entry) =>
                  entry.key == 'editor.fontSize' ||
                  entry.key == 'editor.fontFamily' ||
                  entry.key == 'editor.completionEnabled' ||
                  entry.key == 'view.themeMode' ||
                  entry.key == 'view.language',
            )
            .map((entry) => MapEntry(entry.key, entry.value.value)),
      );
    _effectiveDesktop
      ..clear()
      ..addEntries(
        config.settings.entries
            .where((entry) => !_effectiveApp.containsKey(entry.key))
            .map((entry) => MapEntry(entry.key, entry.value.value)),
      );
    _settings?.applyLuaOverrides(_effectiveApp);
    DesktopPrefsService.instance.applyLuaOverrides(_effectiveDesktop);
    _applyLsp();
  }

  void _applyLsp() {
    final lsp = _lsp;
    if (lsp == null) return;
    unawaited(
      lsp.applyEffectiveEnabled(
        config.valueOf('lsp.enabled') as bool? ??
            DesktopPrefsService.instance.lspEnabled,
      ),
    );
  }

  Map<String, String> keymapFor(Iterable<DesktopCommand> commands) {
    final result = <String, String>{};
    final known = commands.map((command) => command.id).toSet();
    for (final entry in config.keymap.entries) {
      if (!known.contains(entry.key)) continue;
      final binding = entry.value;
      if (binding == null || binding.trim().isEmpty) continue;
      result[entry.key] = binding;
    }
    return result;
  }

  Map<String, Object?> event(
    String type,
    String phase,
    Map<String, Object?> payload,
  ) => {
    'type': type,
    'phase': phase,
    'source': 'slipe',
    'eventId': '${DateTime.now().microsecondsSinceEpoch}',
    'payload': payload,
  };

  void replaceConfigContributions(
    Iterable<LuaConfigContribution> contributions,
  ) => config.replaceAll(contributions);

  void replaceCommandContributions(List<DesktopCommand> commands) {
    _luaCommands = List.unmodifiable(commands);
    notifyListeners();
  }

  /// 用户 init.lua 在窗口创建前执行，窗口尺寸只影响本次 WindowOptions。
  Future<void> loadUserConfig() async {
    if (!DesktopPlatformSupport.isDesktop || _userConfig != null) return;
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'lua'));
    final entry = p.join(root.path, 'config', 'init.lua');
    if (!await File(entry).exists()) return;
    final vm = SlipeLuaVm.open(pluginRoot: root.path);
    try {
      _loadSchema(vm);
      vm.exec(await File(entry).readAsString(), chunkName: '@config/init.lua');
      _userConfig = _configurationOf(vm, LuaConfigService.userConfigId, entry);
      _rebuild(_vms);
    } catch (error) {
      vm.dispose();
      _errors[LuaConfigService.userConfigId] = error.toString();
      debugPrint('Lua 用户配置加载失败：$error');
    }
  }

  /// 串行加载已启用插件；pluginhook.init 在首帧后触发修改授权。
  Future<void> start() {
    if (_started) return _queue;
    _started = true;
    return _enqueue(() async {
      await permissions.ensureLoaded();
      for (final plugin in PluginService.instance.plugins) {
        if (plugin.enabled && plugin.isLua) await _loadPlugin(plugin);
      }
    });
  }

  Future<bool> loadPlugin(InstalledPlugin plugin) => _enqueueBool(() async {
    await permissions.ensureLoaded();
    return _loadPlugin(plugin);
  });

  Future<bool> _loadPlugin(InstalledPlugin plugin) async {
    final manifest = plugin.luaManifest;
    if (manifest == null || !plugin.enabled) return false;
    final vm = SlipeLuaVm.open(pluginRoot: plugin.directory);
    try {
      _loadSchema(vm);
      if (manifest.config.isNotEmpty) {
        vm.exec(
          await File(p.join(plugin.directory, manifest.config)).readAsString(),
          chunkName: '@${manifest.config}',
        );
      }
      vm.exec(
        await File(p.join(plugin.directory, manifest.entry)).readAsString(),
        chunkName: '@${manifest.entry}',
      );
      final requestedHooks = vm.snapshot()['hooks'];
      if (requestedHooks is List) {
        for (final raw in requestedHooks) {
          if (raw is! Map || raw['capability'] != 'editor.modify') continue;
          if (!permissions.isGranted(plugin)) {
            await permissions.requestEditorModify(
              plugin,
              reason: raw['reason'] as String?,
            );
          }
          break;
        }
      }
      final next = Map<String, SlipeLuaVm>.from(_vms);
      final previous = next[manifest.id];
      next[manifest.id] = vm;
      try {
        _rebuild(next);
      } catch (_) {
        _rebuild(_vms);
        rethrow;
      }
      _vms
        ..clear()
        ..addAll(next);
      previous?.dispose();
      _errors.remove(manifest.id);
      notifyListeners();
      return true;
    } catch (error) {
      vm.dispose();
      _errors[manifest.id] = error.toString();
      notifyListeners();
      debugPrint('Lua 插件 ${manifest.id} 加载失败：$error');
      return false;
    }
  }

  /// 语法错误时保留旧 VM；权限失效则先撤销旧贡献。
  Future<bool> reloadPlugin(InstalledPlugin plugin) async {
    final manifest = plugin.luaManifest;
    if (manifest != null &&
        manifest.requestsEditorModify &&
        !permissions.isGranted(plugin)) {
      await unloadPlugin(manifest.id);
    }
    return loadPlugin(plugin);
  }

  Future<void> unloadPlugin(String pluginId, {bool disposeOnly = false}) {
    return _enqueue(() async {
      final vm = _vms.remove(pluginId);
      vm?.dispose();
      registry.removePlugin(pluginId);
      events.removePlugin(pluginId);
      _rebuild(_vms);
      if (!disposeOnly) {
        _errors.remove(pluginId);
        notifyListeners();
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.catchError((error) {
      debugPrint('Lua 运行时队列错误：$error');
    });
    return result;
  }

  Future<bool> _enqueueBool(Future<bool> Function() operation) async {
    var value = false;
    await _enqueue(() async => value = await operation());
    return value;
  }

  Map<String, Object?> _call(
    String pluginId,
    String handler,
    Object? payload, {
    bool resume = false,
    bool isError = false,
  }) {
    final vm = _vms[pluginId];
    if (vm == null) throw StateError('插件 $pluginId 的 VM 未加载');
    return resume
        ? vm.resume(payload, isError: isError)
        : vm.invoke(handler, payload);
  }

  Future<Map<String, Object?>?> _executeEvent(
    LuaEventHook hook,
    Map<String, Object?> event,
  ) async {
    _checkEventPermission(hook);
    final vm = _vms[hook.pluginId];
    if (vm == null) return null;
    return _eventResult(vm.invoke(hook.handler, event));
  }

  Map<String, Object?>? _executeSyncEvent(
    LuaEventHook hook,
    Map<String, Object?> event,
  ) {
    _checkEventPermission(hook);
    final vm = _vms[hook.pluginId];
    if (vm == null) return null;
    return _eventResult(vm.invoke(hook.handler, event));
  }

  void _checkEventPermission(LuaEventHook hook) {
    final granted = hook.phase == 'did'
        ? _pluginDeclares(hook.pluginId, 'events')
        : _isEditorModifyGranted(hook.pluginId);
    if (!granted) throw StateError('插件 ${hook.pluginId} 的事件权限已失效');
  }

  Map<String, Object?>? _eventResult(Map<String, Object?> result) {
    final value = result['result'];
    if (result['status'] == 'done' && value == null) return null;
    if (result['status'] != 'done' || value is! Map) {
      throw StateError('Lua 事件必须同步返回决策对象');
    }
    return _map(value);
  }

  Future<Object?> executeCommand(DesktopCommand command) async {
    for (final entry in _vms.entries) {
      final pluginId = entry.key;
      if (!_pluginDeclares(pluginId, 'commands')) continue;
      final commands = entry.value.snapshot()['commands'];
      if (commands is! Map || commands[command.id] is! Map) continue;
      final registration = _map(commands[command.id] as Map);
      var result = entry.value.invoke(
        registration['handler'] as String,
        const {},
      );
      while (result['status'] == 'yield') {
        Object? response;
        Object? failure;
        try {
          final rawYield = result['yield'];
          if (rawYield is! Map) {
            throw const FormatException('Lua 命令返回了无效挂起请求');
          }
          final yielded = _map(rawYield);
          final rawRequest = yielded['payload'];
          if (yielded['kind'] != 'service' ||
              yielded['service'] != 'ui' ||
              yielded['operation'] != 'notify' ||
              rawRequest is! Map) {
            throw const FormatException('Lua 命令请求了不允许的宿主服务');
          }
          response = await registry.invoke(
            'ui',
            'notify',
            _map(rawRequest),
            _showNotification,
          );
        } catch (error) {
          failure = error;
        }
        result = entry.value.resume(
          failure == null ? response : {'message': failure.toString()},
          isError: failure != null,
        );
      }
      if (result['status'] == 'done') return result['result'];
      throw StateError('Lua 命令 ${command.id} 未返回完成状态');
    }
    throw StateError('Lua 命令 ${command.id} 已注销或所属插件未启用');
  }

  Future<Map<String, Object?>> _showNotification(
    Map<String, Object?> request,
  ) async {
    final messenger = appScaffoldMessengerKey.currentState;
    if (messenger == null) return {'shown': false};
    messenger.showSnackBar(
      SnackBar(content: Text(request['message'] as String)),
    );
    return {'shown': true};
  }

  void _loadSchema(SlipeLuaVm vm) {
    vm.exec(
      'slipe.schema.load(slipe.json.decode(${jsonEncode(slipeApiSchemaJson)}))',
      chunkName: '=slipe-schema',
    );
  }

  void _rebuild(Map<String, SlipeLuaVm> vms) {
    final overrides = <LuaServiceOverride>[];
    final hooks = <LuaEventHook>[];
    final commands = <DesktopCommand>[];
    final configurations = <LuaConfigContribution>[
      if (_userConfig != null) _userConfig!,
    ];
    for (final entry
        in vms.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      final pluginId = entry.key;
      final vm = entry.value;
      final snapshot = vm.snapshot();
      final installed = PluginService.instance.plugins
          .where((item) => item.manifest.id == pluginId)
          .firstOrNull;
      final pluginRoot = installed?.directory;
      final declaresModify =
          installed?.luaManifest?.requestsEditorModify ?? false;
      final canModify = _isEditorModifyGranted(pluginId);
      final services = snapshot['services'];
      if (services is Map) {
        for (final rawList in services.values) {
          if (rawList is! List) continue;
          for (final raw in rawList) {
            final item = _map(raw as Map);
            if (declaresModify && !canModify) continue;
            overrides.add(
              LuaServiceOverride(
                pluginId: pluginId,
                service: item['service'] as String,
                operation: item['operation'] as String,
                handler: item['handler'] as String,
                priority: (item['priority'] as num?)?.toInt() ?? 0,
              ),
            );
          }
        }
      }
      final eventGroups = snapshot['events'];
      if (eventGroups is Map) {
        for (final rawList in eventGroups.values) {
          if (rawList is! List) continue;
          for (final raw in rawList) {
            final item = _map(raw as Map);
            if (item['phase'] == 'will' && declaresModify && !canModify) {
              continue;
            }
            hooks.add(
              LuaEventHook(
                pluginId: pluginId,
                type: item['type'] as String,
                phase: item['phase'] as String,
                handler: item['handler'] as String,
                priority: (item['priority'] as num?)?.toInt() ?? 0,
              ),
            );
          }
        }
      }
      final configuration = _configurationOf(
        vm,
        pluginId,
        pluginRoot ?? pluginId,
        snapshot,
      );
      if (configuration.values.isNotEmpty || configuration.keymap.isNotEmpty) {
        configurations.add(configuration);
      }
      final commandGroup = snapshot['commands'];
      if (commandGroup is Map) {
        if (commandGroup.isNotEmpty && !_pluginDeclares(pluginId, 'commands')) {
          throw StateError('插件 $pluginId 未声明 commands 能力');
        }
        for (final raw in commandGroup.values) {
          final item = _map(raw as Map);
          final id = item['id'] as String;
          late final DesktopCommand command;
          command = DesktopCommand(
            id: id,
            label: item['title'] as String? ?? id,
            description: item['category'] as String? ?? 'Lua 插件',
            run: () => executeCommand(command),
          );
          commands.add(command);
        }
      }
    }
    registry.replaceAll(overrides);
    events.replaceAll(hooks);
    config.replaceAll(configurations);
    replaceCommandContributions(commands);
  }

  LuaConfigContribution _configurationOf(
    SlipeLuaVm vm,
    String pluginId,
    String source, [
    Map<String, Object?>? existingSnapshot,
  ]) {
    final snapshot = existingSnapshot ?? vm.snapshot();
    final rawValues = snapshot['config'];
    final values = <String, Object?>{};
    if (rawValues is Map) {
      for (final entry in rawValues.entries) {
        values[entry.key.toString()] = entry.value;
      }
    }
    final keymap = <String, String?>{};
    final rawKeys = snapshot['keys'];
    if (rawKeys is Map) {
      for (final entry in rawKeys.entries) {
        if (entry.value is String) {
          keymap[entry.value as String] = entry.key.toString();
        }
      }
    }
    return LuaConfigContribution(
      pluginId: pluginId,
      source: source,
      values: values,
      keymap: keymap,
    );
  }

  static Map<String, Object?> _map(Map<dynamic, dynamic> raw) =>
      raw.map((key, value) => MapEntry(key.toString(), value));
}

/// 避免为纯 Dart 单元测试引入 window_manager 的平台判断。
class DesktopPlatformSupport {
  static bool get isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
}
