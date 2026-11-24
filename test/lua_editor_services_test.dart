import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipe_editor/providers/editor_provider.dart';
import 'package:slipe_editor/services/lua/editor_service_adapter.dart';
import 'package:slipe_editor/services/lua/plugin_event_bus.dart';
import 'package:slipe_editor/services/lua/plugin_service_registry.dart';
import 'package:slipe_lua/slipe_lua.dart';

void main() {
  testWidgets('打开、applyEdit、保存均通过真实 Lua Registry 调用链', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('slipe-lua-editor-');
    final vm = SlipeLuaVm.open(pluginRoot: root.path);
    late final EditorProvider provider;
    addTearDown(() {
      provider.dispose();
      vm.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    vm.exec(
      'slipe.schema.load(slipe.json.decode(${jsonEncode(slipeApiSchemaJson)}))',
      chunkName: '=slipe-schema',
    );
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'editor service test' })
      slipe.service.override('editor', 'openFile', function(request, next)
        return next(request)
      end)
      slipe.service.override('editor', 'saveFile', function(request, next)
        request.content = request.content .. '\\n-- saved by Lua'
        return next(request)
      end)
      slipe.service.override('editor', 'applyEdit', function(request, next)
        request.content = request.content .. ' + Lua'
        return next(request)
      end)
    ''');
    final registry = PluginServiceRegistry(isEditorModifyGranted: (_) => true);
    registry.attachLuaBackend(
      (pluginId, handler, payload, {resume = false, isError = false}) => resume
          ? vm.resume(payload, isError: isError)
          : vm.invoke(handler, payload),
    );
    registry.replaceAll(const [
      LuaServiceOverride(
        pluginId: 'test.editor',
        service: 'editor',
        operation: 'openFile',
        handler: 'handler:1',
      ),
      LuaServiceOverride(
        pluginId: 'test.editor',
        service: 'editor',
        operation: 'saveFile',
        handler: 'handler:2',
      ),
      LuaServiceOverride(
        pluginId: 'test.editor',
        service: 'editor',
        operation: 'applyEdit',
        handler: 'handler:3',
      ),
    ]);
    provider = EditorProvider(
      plugins: EditorServiceAdapter(
        registry: registry,
        events: PluginEventBus(),
      ),
    );
    final file = File('${root.path}/demo.dart')..writeAsStringSync('original');

    final opened = await tester.runAsync(() => provider.openFile(file.path));
    expect(opened, isNotNull);
    expect(
      await tester.runAsync(() => provider.applyEdit(file.path, 'changed')),
      isTrue,
    );
    expect(provider.activeFile!.content, 'changed + Lua');
    expect(
      await tester.runAsync(
        () => provider.saveContent(file.path, provider.activeFile!.content),
      ),
      isTrue,
    );
    expect(file.readAsStringSync(), 'changed + Lua\n-- saved by Lua');
    expect(provider.activeFile!.isModified, isFalse);
  });
}
