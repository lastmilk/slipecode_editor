import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/services/lua/plugin_service_registry.dart';
import 'package:slipe_lua/slipe_lua.dart';

void main() {
  late Directory pluginRoot;
  late SlipeLuaVm vm;

  setUp(() {
    pluginRoot = Directory.systemTemp.createTempSync('slipe-ffi-registry-');
    vm = SlipeLuaVm.open(pluginRoot: pluginRoot.path);
    vm.exec(
      'slipe.schema.load(slipe.json.decode(${jsonEncode(slipeApiSchemaJson)}))',
      chunkName: '=slipe-schema',
    );
  });

  tearDown(() {
    vm.dispose();
    if (pluginRoot.existsSync()) pluginRoot.deleteSync(recursive: true);
  });

  PluginServiceRegistry registryWithVm() {
    final registry = PluginServiceRegistry(isEditorModifyGranted: (_) => true);
    registry.attachLuaBackend(
      (pluginId, handler, payload, {resume = false, isError = false}) => resume
          ? vm.resume(payload, isError: isError)
          : vm.invoke(handler, payload),
    );
    return registry;
  }

  test('真实协程经 Registry next 修改请求并包裹默认响应', () async {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'FFI test' })
      slipe.service.override('command', 'execute', function(request, next)
        local response = next({ id = request.id .. ':next' })
        return { id = response.id, executed = response.executed, wrapped = true }
      end)
    ''');
    final registry = registryWithVm()
      ..replaceAll([
        const LuaServiceOverride(
          pluginId: 'test.ffi',
          service: 'command',
          operation: 'execute',
          handler: 'handler:1',
        ),
      ]);

    final result = await registry.invoke('command', 'execute', {
      'id': 'demo',
    }, (request) async => {'id': request['id'], 'executed': true});
    expect(result, {'id': 'demo:next', 'executed': true, 'wrapped': true});
  });

  test('next 等待期间重载会在 resume 前取消旧代际', () async {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'generation test' })
      slipe.service.override('command', 'execute', function(request, next)
        return next(request)
      end)
    ''');
    final registry = registryWithVm()
      ..replaceAll([
        const LuaServiceOverride(
          pluginId: 'test.ffi',
          service: 'command',
          operation: 'execute',
          handler: 'handler:1',
        ),
      ]);
    final started = Completer<void>();
    final defaultResult = Completer<Object?>();
    final invocation = registry.invoke('command', 'execute', {'id': 'old'}, (
      request,
    ) {
      started.complete();
      return defaultResult.future;
    });
    final expectation = expectLater(
      invocation,
      throwsA(isA<PluginGenerationChangedException>()),
    );
    await started.future;
    registry.replaceAll(const []);
    defaultResult.complete({'id': 'old', 'executed': true});
    await expectation;
  });

  test('Lua 返回错误结构时在 FFI 边界被拒绝', () async {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'schema test' })
      slipe.service.override('completion', 'list', function(request, next)
        return {}
      end)
    ''');
    final registry = registryWithVm()
      ..replaceAll([
        const LuaServiceOverride(
          pluginId: 'test.ffi',
          service: 'completion',
          operation: 'list',
          handler: 'handler:1',
        ),
      ]);

    await expectLater(
      registry.invoke('completion', 'list', {
        'language': 'dart',
        'text': '',
        'cursor': 0,
        'items': const [],
      }, (_) async => {'items': const []}),
      throwsA(isA<SlipeLuaException>()),
    );
  });
}
