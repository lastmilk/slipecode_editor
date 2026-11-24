import 'lua_runtime_service.dart';
import 'plugin_event_bus.dart';
import 'plugin_service_registry.dart';

/// EditorProvider 与 Lua 宿主之间的稳定边界，测试可注入纯 Dart fake。
class EditorServiceAdapter {
  EditorServiceAdapter({
    PluginServiceRegistry? registry,
    PluginEventBus? events,
  }) : registry = registry ?? LuaRuntimeService.instance.registry,
       events = events ?? LuaRuntimeService.instance.events;

  final PluginServiceRegistry registry;
  final PluginEventBus events;

  Map<String, Object?> event(
    String type,
    String phase,
    Map<String, Object?> payload,
  ) => LuaRuntimeService.instance.event(type, phase, payload);
}
