import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:slipe_editor/services/app_globals.dart';
import 'package:slipe_editor/services/lua/lua_permission_service.dart';
import 'package:slipe_editor/services/lua/lua_runtime_service.dart';
import 'package:slipe_editor/services/plugin_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('安装、授权、事件、热重载、禁用和卸载管理真实 VM', (tester) async {
    final support = Directory.systemTemp.createTempSync('slipe-lua-runtime-');
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: appScaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );

    var allowModify = false;
    final prompts = <String>[];
    final permissions = LuaPermissionService.instance;
    permissions.dialogHandler = (request) async {
      prompts.add(request.plugin.manifest.id);
      return allowModify;
    };
    await tester.runAsync(() async {
      // 在 runAsync Zone 内创建运行时，避免队列 Future 绑定到 fake-async Zone。
      final plugins = PluginService.instance;
      final runtime = LuaRuntimeService.instance;
      await plugins.ensureLoaded();
      expect(plugins.plugins, isEmpty);

      final hello = await plugins.installFromDirectory(
        _example('example.hello'),
      );
      expect(runtime.isVmLoaded(hello.manifest.id), isTrue);
      expect(runtime.config.valueOf('editor.fontSize'), 15);
      expect(runtime.config.keymap['example.hello'], 'ctrl+alt+l');
      expect(prompts, isEmpty);
      final helloCommand = runtime.luaCommands.singleWhere(
        (command) => command.id == 'example.hello',
      );
      await runtime.executeCommand(helloCommand);

      final aop = await plugins.installFromDirectory(
        _example('example.aop-completion'),
      );
      expect(prompts, ['example.aop-completion']);
      expect(runtime.isVmLoaded(aop.manifest.id), isTrue);
      expect(
        runtime.registry.overrides.where(
          (item) => item.pluginId == aop.manifest.id,
        ),
        isEmpty,
      );
      expect((await _completion(runtime))['items'], hasLength(1));

      allowModify = true;
      expect(
        await permissions.requestEditorModify(aop, askAgain: true),
        isTrue,
      );
      expect(await runtime.loadPlugin(aop), isTrue);
      expect((await _completion(runtime))['items'], hasLength(2));

      final installedEntry = File(p.join(aop.directory, 'main.lua'));
      final originalAop = installedEntry.readAsStringSync();
      installedEntry.writeAsStringSync(
        originalAop.replaceAll('Lua AOP Example', 'Lua AOP Reloaded'),
      );
      allowModify = false;
      final changed = await plugins.refreshLuaPlugin(aop.manifest.id);
      expect(changed, isNotNull);
      expect(permissions.isGranted(changed!), isFalse);
      expect(
        runtime.registry.overrides.where(
          (item) => item.pluginId == aop.manifest.id,
        ),
        isEmpty,
      );
      expect((await _completion(runtime))['items'], hasLength(1));

      allowModify = true;
      expect(
        await permissions.requestEditorModify(changed, askAgain: true),
        isTrue,
      );
      expect(await runtime.loadPlugin(changed), isTrue);
      var items = (await _completion(runtime))['items']! as List<Object?>;
      expect((items.last! as Map)['label'], 'Lua AOP Reloaded');

      installedEntry.writeAsStringSync('this is not valid Lua');
      expect(await runtime.reloadPlugin(changed), isFalse);
      expect(runtime.errorFor(changed.manifest.id), isNotNull);
      expect(runtime.isVmLoaded(changed.manifest.id), isTrue);
      items = (await _completion(runtime))['items']! as List<Object?>;
      expect((items.last! as Map)['label'], 'Lua AOP Reloaded');

      await runtime.unloadPlugin(changed.manifest.id);
      await permissions.revoke(changed.manifest.id);
      expect(runtime.isVmLoaded(changed.manifest.id), isFalse);
      expect((await _completion(runtime))['items'], hasLength(1));

      final guard = await plugins.installFromDirectory(
        _example('example.event-guard'),
      );
      expect(runtime.isVmLoaded(guard.manifest.id), isTrue);
      final ordinary = await runtime.events.dispatch(
        'file.willSave',
        runtime.event('file.willSave', 'will', {
          'path': 'lib/main.dart',
          'content': 'x',
        }),
      );
      expect(ordinary.swallowed, isFalse);
      final guarded = await runtime.events.dispatch(
        'file.willSave',
        runtime.event('file.willSave', 'will', {
          'path': 'tmp/demo.lua-guard',
          'content': 'x',
        }),
      );
      final guardedPayload = guarded.event['payload']! as Map;
      expect(guardedPayload['content'], '-- Lua event guard: reviewed\nx');
      final swallowed = await runtime.events.dispatch(
        'file.willSave',
        runtime.event('file.willSave', 'will', {
          'path': 'tmp/demo.lua-guard',
          'content': 'SLIPE_BLOCK_SAVE',
        }),
      );
      expect(swallowed.swallowed, isTrue);

      await plugins.setEnabled(guard.manifest.id, false);
      expect(runtime.isVmLoaded(guard.manifest.id), isFalse);
      expect(runtime.events.hasHooks('file.willSave'), isFalse);

      for (final plugin in plugins.plugins.toList()) {
        await plugins.uninstall(plugin.manifest.id);
      }
      expect(plugins.plugins, isEmpty);
      expect(runtime.config.valueOf('editor.fontSize'), isNull);
    });

    await tester.pump();
    expect(find.text('你好，来自 example.hello！'), findsOneWidget);

    permissions.dialogHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (support.existsSync()) support.deleteSync(recursive: true);
  });
}

String _example(String id) =>
    p.join(Directory.current.path, 'examples', 'lua_plugins', id);

Future<Map<String, Object?>> _completion(LuaRuntimeService runtime) async {
  final result = await runtime.registry.invoke('completion', 'list', {
    'language': 'dart',
    'text': 'print',
    'cursor': 5,
    'items': const [
      {'label': 'print', 'insertText': 'print', 'kindLabel': 'built-in'},
    ],
  }, (request) async => {'items': request['items']});
  return result! as Map<String, Object?>;
}
