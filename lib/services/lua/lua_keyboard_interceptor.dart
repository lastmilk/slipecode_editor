import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../command_registry.dart';
import 'lua_runtime_service.dart';
import 'plugin_event_bus.dart';

/// 在 TextField/CallbackShortcuts 之前同步处理 editor.key。
/// Expando 防止同一次原生事件沿 Focus 链被多层重复拦截。
class LuaKeyboardInterceptor {
  static final Expando<bool> _processed = Expando<bool>('lua-editor-key');

  static KeyEventResult handle(
    KeyEvent keyEvent, {
    required PluginEventBus events,
    required Map<ShortcutActivator, VoidCallback> bindings,
    String source = 'editor',
  }) {
    if (!events.hasHooks('editor.key')) return KeyEventResult.ignored;
    if (_processed[keyEvent] == true) return KeyEventResult.ignored;
    _processed[keyEvent] = true;

    final action = switch (keyEvent) {
      KeyRepeatEvent() => 'repeat',
      KeyDownEvent() => 'down',
      KeyUpEvent() => 'up',
      _ => 'unknown',
    };
    final keyboard = HardwareKeyboard.instance;
    final event = LuaRuntimeService.instance.event('editor.key', 'will', {
      'key': keyEvent.logicalKey.keyLabel.toLowerCase(),
      'keyId': keyEvent.logicalKey.keyId,
      'action': action,
      'control': keyboard.isControlPressed,
      'meta': keyboard.isMetaPressed,
      'shift': keyboard.isShiftPressed,
      'alt': keyboard.isAltPressed,
    });
    event['source'] = source;
    final result = events.dispatchSync('editor.key', event);
    if (result.swallowed) return KeyEventResult.handled;
    if (result.action != PluginEventAction.modify)
      return KeyEventResult.ignored;

    final payload = result.event['payload'];
    if (payload is! Map) return KeyEventResult.handled;
    final key = payload['key'];
    if (key is! String || key.isEmpty) return KeyEventResult.handled;
    final chord = [
      if (payload['control'] == true) 'ctrl',
      if (payload['meta'] == true) 'cmd',
      if (payload['shift'] == true) 'shift',
      if (payload['alt'] == true) 'alt',
      key,
    ].join('+');
    final activator = parseLuaKeyBinding(chord);
    final callback = activator == null ? null : bindings[activator];
    callback?.call();
    // 已授权的事件修改不得再触发原按键的默认行为。
    return KeyEventResult.handled;
  }
}
