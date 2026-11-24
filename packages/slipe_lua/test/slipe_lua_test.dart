import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_lua/slipe_lua.dart';

void main() {
  late Directory pluginRoot;
  late SlipeLuaVm vm;

  setUp(() {
    pluginRoot = Directory.systemTemp.createTempSync('slipe_lua_test_');
    vm = SlipeLuaVm.open(pluginRoot: pluginRoot.path);
  });

  tearDown(() {
    vm.dispose();
    if (pluginRoot.existsSync()) pluginRoot.deleteSync(recursive: true);
  });

  test('executes real LuaJIT arithmetic and preserves UTF-8', () {
    final response = vm.exec(
      "return { answer = 6 * 7, message = '你好, SLIPE 🌍' }",
    );

    expect(response['status'], 'done');
    expect(response['result'], {
      'answer': 42,
      'message': '你好, SLIPE 🌍',
    });
  });

  test('registrations are private VM data exposed by snapshot', () {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'test grant' })
      slipe.commands.register('example.hello', { title = 'Lua Hello' }, function() end)
      slipe.events.on('file.willSave', { phase = 'will' }, function(event) end)
      slipe.service.override('completion', 'list', { priority = 20 }, function(request, next) end)
      slipe.config.set('editor.fontSize', 15)
      slipe.keys.bind('ctrl+alt+l', 'example.hello')
      slipe.keys.unbind('ctrl+shift+b')
    ''');

    final snapshot = vm.snapshot();
    final commands = snapshot['commands']! as Map<String, Object?>;
    final command = commands['example.hello']! as Map<String, Object?>;
    final events = snapshot['events']! as Map<String, Object?>;
    final services = snapshot['services']! as Map<String, Object?>;
    final serviceList = services['completion.list']! as List<Object?>;
    final service = serviceList.single! as Map<String, Object?>;
    final config = snapshot['config']! as Map<String, Object?>;
    final keys = snapshot['keys']! as Map<String, Object?>;
    final hooks = snapshot['hooks']! as List<Object?>;

    expect(command['title'], 'Lua Hello');
    expect(command['handler'], 'handler:1');
    expect(events['file.willSave'], hasLength(1));
    expect(service['priority'], 20);
    expect(service['handler'], 'handler:3');
    expect(config['editor.fontSize'], 15);
    expect(keys['ctrl+alt+l'], 'example.hello');
    expect(keys['ctrl+shift+b'], false);
    expect(hooks, hasLength(1));
  });

  test('editor modification requires explicit pluginhook.init', () {
    expect(
      () => vm.exec('''
        slipe.service.override('completion', 'list', function(request, next)
          return next(request)
        end)
      '''),
      throwsA(
        isA<SlipeLuaException>().having(
          (error) => error.message,
          'message',
          contains('pluginhook.init'),
        ),
      ),
    );
  });

  test('invoke yields next and resume completes the same coroutine', () {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'test grant' })
      slipe.service.override('completion', 'list', function(request, next)
        local response = next({ n = request.n + 1 })
        return { n = response.n * 2 }
      end)
    ''');

    final yielded = vm.invoke('handler:1', {'n': 3});
    expect(yielded['status'], 'yield');
    expect(yielded['yield'], {
      'kind': 'next',
      'payload': {'n': 4},
    });

    final completed = vm.resume({'n': 5});
    expect(completed, {
      'status': 'done',
      'result': {'n': 10},
    });
  });

  test('resume can deliver a host error back into pcall', () {
    vm.exec('''
      pluginhook.init({ capability = 'editor.modify', reason = 'test grant' })
      slipe.service.override('command', 'execute', function(request, next)
        local ok, err = pcall(function() return next() end)
        return { ok = ok, message = err.message }
      end)
    ''');

    expect(vm.invoke('handler:1', {'command': 'example'})['status'], 'yield');
    final completed = vm.resume({'message': 'denied'}, isError: true);
    expect(completed['result'], {'ok': false, 'message': 'denied'});
  });

  test('instruction budget stops an infinite loop and VM remains usable', () {
    expect(
      () => vm.exec('while true do end', instructionBudget: 2000),
      throwsA(
        isA<SlipeLuaException>().having(
          (error) => error.message,
          'message',
          contains('instruction budget'),
        ),
      ),
    );
    expect(vm.exec('return 40 + 2')['result'], 42);
  });

  test('created coroutines share the active instruction budget', () {
    expect(
      () => vm.exec('''
        local co = coroutine.create(function() while true do end end)
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 0) end
        return ok
      ''', instructionBudget: 5000),
      throwsA(
        isA<SlipeLuaException>().having(
          (error) => error.message,
          'message',
          contains('instruction budget'),
        ),
      ),
    );

    expect(
      () => vm.exec('''
        local run = coroutine.wrap(function() while true do end end)
        return run()
      ''', instructionBudget: 5000),
      throwsA(isA<SlipeLuaException>()),
    );
  });

  test('allocator enforces the independent VM memory limit', () {
    final limited = SlipeLuaVm.open(
      pluginRoot: pluginRoot.path,
      memoryLimit: 4 * 1024 * 1024,
    );
    addTearDown(limited.dispose);

    expect(
      () => limited.exec('''
        local values = {}
        for index = 1, 100000 do
          values[index] = string.rep('x', 4096) .. index
        end
      ''', instructionBudget: 2000000),
      throwsA(
        isA<SlipeLuaException>().having(
          (error) => error.message,
          'message',
          contains('memory limit'),
        ),
      ),
    );
  });

  test('require loads only text Lua modules below the plugin root', () {
    File('${pluginRoot.path}/math_util.lua').writeAsStringSync(
      'return { triple = function(n) return n * 3 end }',
    );
    Directory('${pluginRoot.path}/nested').createSync();
    File('${pluginRoot.path}/nested/value.lua').writeAsStringSync(
      'return { value = 7 }',
    );

    final response = vm.exec('''
      local math_util = require('math_util')
      local nested = require('nested.value')
      local escaped = pcall(require, '../outside')
      local native = pcall(require, 'ffi')
      return {
        answer = math_util.triple(nested.value),
        escaped = escaped,
        native = native
      }
    ''');

    expect(response['result'], {
      'answer': 21,
      'escaped': false,
      'native': false,
    });
  });

  test('dangerous standard library entry points are unavailable', () {
    final response = vm.exec('''
      return {
        ffi = ffi == nil,
        execute = os.execute == nil,
        exit = os.exit == nil,
        popen = io.popen == nil,
        loadlib = package.loadlib == nil,
        debug = debug == nil,
        loadfile = loadfile == nil,
        dofile = dofile == nil,
        extraLoader = package.loaders[2] == nil
      }
    ''');

    final result = response['result']! as Map<String, Object?>;
    expect(result.values.every((value) => value == true), isTrue);
  });

  test('JSON null, arrays and schema validation survive the Lua boundary', () {
    final response = vm.exec('''
      local value = slipe.json.decode('{"items":[1,null,"你好"]}')
      slipe.schema.load({
        type = 'object',
        required = { 'count' },
        properties = { count = { type = 'integer', minimum = 1 } },
        additionalProperties = false
      })
      local valid = slipe.schema.validate({ count = 2 })
      local invalid, message = slipe.schema.validate({ count = 'bad' })
      return {
        encoded = slipe.json.encode(value),
        valid = valid,
        invalid = invalid == nil,
        message = message
      }
    ''');

    expect(response['result'], {
      'encoded': '{"items":[1,null,"你好"]}',
      'valid': true,
      'invalid': true,
      'message': r'$.count: expected integer, got string',
    });
  });

  test('invalid handler and disposal produce explicit errors', () {
    expect(
      () => vm.invoke('handler:missing', {}),
      throwsA(isA<SlipeLuaException>()),
    );
    vm.dispose();
    vm.dispose();
    expect(() => vm.snapshot(), throwsStateError);
  });
}
