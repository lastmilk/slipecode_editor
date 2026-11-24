import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/services/lua/plugin_service_registry.dart';

void main() {
  LuaServiceOverride override(
    String plugin,
    String handler, {
    int priority = 0,
  }) => LuaServiceOverride(
    pluginId: plugin,
    service: 'command',
    operation: 'execute',
    handler: handler,
    priority: priority,
  );

  test('没有覆盖时直接走默认实现', () async {
    final registry = PluginServiceRegistry();
    var calls = 0;
    final result = await registry.invoke('command', 'execute', {'id': 'a'}, (
      request,
    ) async {
      calls++;
      return request['id'];
    });
    expect(result, 'a');
    expect(calls, 1);
  });

  test('高优先级在外层，next 依次进入默认实现', () async {
    final trace = <String>[];
    final registry = PluginServiceRegistry(
      isEditorModifyGranted: (_) => true,
      executor: (item, request, next) async {
        trace.add('${item.pluginId}:before');
        final result = await next(request);
        trace.add('${item.pluginId}:after');
        return '$result:${item.pluginId}';
      },
    );
    registry.replaceAll([override('b', 'b'), override('a', 'a', priority: 10)]);
    final result = await registry.invoke('command', 'execute', {'id': 'test'}, (
      request,
    ) async {
      trace.add('default');
      return 'ok';
    });
    expect(result, 'ok:b:a');
    expect(trace, ['a:before', 'b:before', 'default', 'b:after', 'a:after']);
  });

  test('未授权插件即使绕过 init 也不能注册', () {
    final registry = PluginServiceRegistry();
    expect(
      () => registry.replaceAll([override('bad', 'bad')]),
      throwsA(isA<PluginServiceRegistryException>()),
    );
  });

  test('同一个 handler 不能调用两次 next', () async {
    final registry = PluginServiceRegistry(
      isEditorModifyGranted: (_) => true,
      executor: (item, request, next) async {
        await next(request);
        return next(request);
      },
    )..replaceAll([override('a', 'a')]);
    expect(
      () => registry.invoke('command', 'execute', {
        'id': 'test',
      }, (_) async => null),
      throwsA(isA<PluginServiceRegistryException>()),
    );
  });

  test('重载后旧调用被代际检查取消', () async {
    late final PluginServiceRegistry registry;
    registry = PluginServiceRegistry(
      isEditorModifyGranted: (_) => true,
      executor: (item, request, next) async {
        registry.replaceAll([]);
        return next(request);
      },
    )..replaceAll([override('a', 'a')]);
    expect(
      () => registry.invoke('command', 'execute', {
        'id': 'test',
      }, (_) async => null),
      throwsA(isA<PluginGenerationChangedException>()),
    );
  });
}
