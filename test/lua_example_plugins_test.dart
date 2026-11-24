import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:slipe_lua/slipe_lua.dart';

void main() {
  late SlipeLuaVm vm;

  SlipeLuaVm openExample(String id) {
    final root = p.join(Directory.current.path, 'examples', 'lua_plugins', id);
    final instance = SlipeLuaVm.open(pluginRoot: root);
    instance.exec(
      'slipe.schema.load(slipe.json.decode(${jsonEncode(slipeApiSchemaJson)}))',
      chunkName: '=slipe-schema',
    );
    return instance;
  }

  void execEntry(SlipeLuaVm instance, String id, String name) {
    final file = File(
      p.join(Directory.current.path, 'examples', 'lua_plugins', id, name),
    );
    instance.exec(file.readAsStringSync(), chunkName: '@$name');
  }

  tearDown(() {
    vm.dispose();
  });

  test(
    'example.hello runs configuration, key binding, command and ui.notify',
    () {
      vm = openExample('example.hello');
      execEntry(vm, 'example.hello', 'config.lua');
      execEntry(vm, 'example.hello', 'main.lua');

      final snapshot = vm.snapshot();
      final config = snapshot['config']! as Map<String, Object?>;
      final keys = snapshot['keys']! as Map<String, Object?>;
      final commands = snapshot['commands']! as Map<String, Object?>;
      final command = commands['example.hello']! as Map<String, Object?>;
      expect(config['editor.fontSize'], 15);
      expect(keys['ctrl+alt+l'], 'example.hello');

      final called = vm.invoke(command['handler']! as String, const {});
      expect(called['status'], 'yield');
      expect(called['yield'], {
        'kind': 'service',
        'service': 'ui',
        'operation': 'notify',
        'payload': {'message': '你好，来自 example.hello！', 'level': 'info'},
      });
      expect(vm.resume({'shown': true})['status'], 'done');
    },
  );

  test(
    'example.aop-completion preserves defaults and appends through next',
    () {
      vm = openExample('example.aop-completion');
      execEntry(vm, 'example.aop-completion', 'main.lua');

      final snapshot = vm.snapshot();
      final services = snapshot['services']! as Map<String, Object?>;
      final overrides = services['completion.list']! as List<Object?>;
      final registration = overrides.single! as Map<String, Object?>;
      final request = <String, Object?>{
        'language': 'dart',
        'text': 'print',
        'cursor': 5,
        'items': [
          {'label': 'print', 'insertText': 'print', 'kindLabel': 'built-in'},
        ],
      };
      final yielded = vm.invoke(registration['handler']! as String, request);
      expect(yielded['status'], 'yield');
      expect(yielded['yield'], {'kind': 'next', 'payload': request});

      final completed = vm.resume({'items': request['items']});
      expect(completed['status'], 'done');
      final response = completed['result']! as Map<String, Object?>;
      final items = response['items']! as List<Object?>;
      expect(items, hasLength(2));
      expect((items.first! as Map)['label'], 'print');
      expect((items.last! as Map)['label'], 'Lua AOP Example');
    },
  );

  test(
    'example.event-guard continues, modifies and swallows only test events',
    () {
      vm = openExample('example.event-guard');
      execEntry(vm, 'example.event-guard', 'main.lua');

      final snapshot = vm.snapshot();
      final events = snapshot['events']! as Map<String, Object?>;
      final saveHooks = events['file.willSave']! as List<Object?>;
      final keyHooks = events['editor.key']! as List<Object?>;
      final saveHandler = (saveHooks.single! as Map)['handler'] as String;
      final keyHandler = (keyHooks.single! as Map)['handler'] as String;

      Map<String, Object?> saveEvent(String path, String content) => {
        'type': 'file.willSave',
        'phase': 'will',
        'source': 'test',
        'eventId': 'save-${vm.snapshot().hashCode}',
        'payload': {'path': path, 'content': content},
      };

      final ordinary = vm.invoke(saveHandler, saveEvent('lib/main.dart', 'x'));
      expect((ordinary['result']! as Map)['action'], 'continue');

      final modified = vm.invoke(
        saveHandler,
        saveEvent('tmp/demo.lua-guard', 'print("ok")'),
      );
      final modifiedResult = modified['result']! as Map<String, Object?>;
      expect(modifiedResult['action'], 'modify');
      final modifiedEvent = modifiedResult['event']! as Map<String, Object?>;
      final modifiedPayload = modifiedEvent['payload']! as Map<String, Object?>;
      expect(
        modifiedPayload['content'],
        '-- Lua event guard: reviewed\nprint("ok")',
      );

      final swallowed = vm.invoke(
        saveHandler,
        saveEvent('tmp/demo.lua-guard', 'SLIPE_BLOCK_SAVE'),
      );
      expect((swallowed['result']! as Map)['action'], 'swallow');

      final key = vm.invoke(keyHandler, {
        'type': 'editor.key',
        'phase': 'will',
        'source': 'test',
        'eventId': 'key-1',
        'payload': {
          'key': 'f9',
          'keyId': 0,
          'action': 'down',
          'control': true,
          'alt': true,
          'meta': false,
          'shift': false,
        },
      });
      expect((key['result']! as Map)['action'], 'swallow');
    },
  );
}
