import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/services/lua/plugin_event_bus.dart';

void main() {
  LuaEventHook hook({String phase = 'will', String type = 'file.willSave'}) =>
      LuaEventHook(pluginId: 'a', type: type, phase: phase, handler: 'handler');

  Map<String, Object?> event({String phase = 'will'}) => {
    'type': phase == 'will' ? 'file.willSave' : 'file.didSave',
    'phase': phase,
    'payload': {'path': 'a.dart'},
  };

  test('continue 与 modify 依次传递', () async {
    final bus = PluginEventBus(
      isEditorModifyGranted: (_) => true,
      executor: (hook, current) async => {
        'action': 'modify',
        'event': {
          ...current,
          'payload': {'path': 'changed.dart'},
        },
      },
    )..replaceAll([hook()]);
    final result = await bus.dispatch('file.willSave', event());
    expect(result.swallowed, isFalse);
    expect((result.event['payload'] as Map)['path'], 'changed.dart');
  });

  test('will 阶段可以吞掉，did 阶段不能吞掉', () async {
    final bus = PluginEventBus(
      isEditorModifyGranted: (_) => true,
      hasCapability: (_, _) => true,
      executor: (_, _) async => {'action': 'swallow'},
    )..replaceAll([hook()]);
    expect((await bus.dispatch('file.willSave', event())).swallowed, isTrue);

    bus.replaceAll([hook(phase: 'did', type: 'file.didSave')]);
    expect(
      () => bus.dispatch('file.didSave', event(phase: 'did')),
      throwsA(isA<PluginEventException>()),
    );
  });

  test('did 订阅要求 events，will 修改要求 editor.modify', () {
    final bus = PluginEventBus();
    expect(
      () => bus.replaceAll([hook()]),
      throwsA(isA<PluginEventException>()),
    );
    expect(
      () => bus.replaceAll([hook(phase: 'did', type: 'file.didSave')]),
      throwsA(isA<PluginEventException>()),
    );
  });

  test('键盘钩子异常 fail-open 并禁用出错钩子', () async {
    var calls = 0;
    LuaEventHook? failed;
    final bus = PluginEventBus(
      isEditorModifyGranted: (_) => true,
      onError: (hook, _) => failed = hook,
      executor: (_, _) async {
        calls++;
        throw StateError('bad lua');
      },
    )..replaceAll([hook(type: 'editor.key')]);
    final keyEvent = {'type': 'editor.key', 'phase': 'will'};
    final result = await bus.dispatch('editor.key', keyEvent, failOpen: true);
    expect(result.swallowed, isFalse);
    expect(failed, isNotNull);
    await bus.dispatch('editor.key', keyEvent, failOpen: true);
    expect(calls, 1);
  });

  test('同步键盘钩子支持吞掉与修改，异常时不等待 Future', () {
    var calls = 0;
    final bus = PluginEventBus(
      isEditorModifyGranted: (_) => true,
      syncExecutor: (_, current) {
        calls++;
        if ((current['payload'] as Map)['key'] == 'escape') {
          return {'action': 'swallow'};
        }
        return {
          'action': 'modify',
          'event': {
            ...current,
            'payload': {...(current['payload'] as Map), 'key': 'enter'},
          },
        };
      },
    )..replaceAll([hook(type: 'editor.key')]);

    final swallowed = bus.dispatchSync('editor.key', {
      'type': 'editor.key',
      'phase': 'will',
      'payload': {'key': 'escape'},
    });
    expect(swallowed.swallowed, isTrue);
    final modified = bus.dispatchSync('editor.key', {
      'type': 'editor.key',
      'phase': 'will',
      'payload': {'key': 'tab'},
    });
    expect((modified.event['payload'] as Map)['key'], 'enter');
    expect(calls, 2);
  });

  test('事件钩子不能篡改 type 或 phase', () async {
    final bus = PluginEventBus(
      isEditorModifyGranted: (_) => true,
      executor: (_, current) async => {
        'action': 'modify',
        'event': {...current, 'type': 'file.didSave'},
      },
    )..replaceAll([hook()]);
    expect(
      () => bus.dispatch('file.willSave', event()),
      throwsA(isA<PluginEventException>()),
    );
  });
}
