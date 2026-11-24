import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 桌面命令：菜单、命令面板、快捷键共用同一份定义，避免三处漂移。
class DesktopCommand {
  final String id;
  final String label;
  final String? description;
  final String? hint;
  final ShortcutActivator? activator;
  final bool enabled;
  final Future<void> Function() run;

  const DesktopCommand({
    required this.id,
    required this.label,
    required this.run,
    this.description,
    this.hint,
    this.activator,
    this.enabled = true,
  });

  String get shortcutLabel =>
      activator == null ? '' : describeActivator(activator!);

  DesktopCommand copyWith({
    ShortcutActivator? activator,
    bool clearActivator = false,
    bool? enabled,
    Future<void> Function()? run,
  }) => DesktopCommand(
    id: id,
    label: label,
    description: description,
    hint: hint,
    activator: clearActivator ? null : activator ?? this.activator,
    enabled: enabled ?? this.enabled,
    run: run ?? this.run,
  );
}

/// 将内置命令、Lua 命令和 Lua 键位覆盖组合成唯一事实来源。
class DesktopCommandRegistry {
  const DesktopCommandRegistry();

  List<DesktopCommand> compose(
    List<DesktopCommand> builtins, {
    Iterable<DesktopCommand> luaCommands = const [],
    Map<String, String?> keymap = const {},
  }) {
    final result = List<DesktopCommand>.of(builtins);
    final ids = result.map((item) => item.id).toSet();
    for (final command in luaCommands) {
      if (!ids.add(command.id)) {
        throw ArgumentError('Lua 插件注册了重复命令：${command.id}');
      }
      result.add(command);
    }
    return [
      for (final command in result)
        if (keymap.containsKey(command.id))
          command.copyWith(
            activator: parseLuaKeyBinding(keymap[command.id] ?? ''),
            clearActivator: (keymap[command.id] ?? '').trim().isEmpty,
          )
        else
          command,
    ];
  }
}

/// 解析 Lua 配置中的 ctrl+alt+l / cmd+shift+p 等键位。
SingleActivator? parseLuaKeyBinding(String source) {
  final parts = source
      .toLowerCase()
      .split('+')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  var control = false;
  var meta = false;
  var shift = false;
  var alt = false;
  LogicalKeyboardKey? trigger;
  for (final part in parts) {
    switch (part) {
      case 'ctrl' || 'control':
        control = true;
      case 'cmd' || 'meta' || 'super':
        meta = true;
      case 'shift':
        shift = true;
      case 'alt' || 'option':
        alt = true;
      default:
        if (trigger != null) return null;
        trigger = _luaKeys[part];
        if (trigger == null) return null;
    }
  }
  if (trigger == null) return null;
  return SingleActivator(
    trigger,
    control: control,
    meta: meta,
    shift: shift,
    alt: alt,
  );
}

final Map<String, LogicalKeyboardKey> _luaKeys = {
  for (var i = 0; i < 26; i++)
    String.fromCharCode(97 + i): LogicalKeyboardKey(
      LogicalKeyboardKey.keyA.keyId + i,
    ),
  for (var i = 0; i < 10; i++)
    '$i': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i),
  for (var i = 1; i <= 12; i++)
    'f$i': LogicalKeyboardKey(LogicalKeyboardKey.f1.keyId + i - 1),
  'tab': LogicalKeyboardKey.tab,
  'enter': LogicalKeyboardKey.enter,
  'esc': LogicalKeyboardKey.escape,
  'escape': LogicalKeyboardKey.escape,
  'space': LogicalKeyboardKey.space,
  'backquote': LogicalKeyboardKey.backquote,
  'comma': LogicalKeyboardKey.comma,
  'period': LogicalKeyboardKey.period,
  'slash': LogicalKeyboardKey.slash,
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
};

bool get isMacDesktop => defaultTargetPlatform == TargetPlatform.macOS;

/// 统一生成桌面快捷键：macOS 用 Cmd，其余平台用 Ctrl。
SingleActivator desktopActivator(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  return SingleActivator(
    key,
    control: !isMacDesktop,
    meta: isMacDesktop,
    shift: shift,
    alt: alt,
  );
}

String describeActivator(ShortcutActivator activator) {
  if (activator is! SingleActivator) return '';
  final parts = <String>[];
  if (activator.control) parts.add('Ctrl');
  if (activator.meta) parts.add('Cmd');
  if (activator.alt) parts.add('Alt');
  if (activator.shift) parts.add('Shift');
  parts.add(_keyLabel(activator.trigger));
  return parts.join('+');
}

String _keyLabel(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.isNotEmpty) return label;
  switch (key) {
    case LogicalKeyboardKey.backquote:
      return '`';
    case LogicalKeyboardKey.period:
      return '.';
    case LogicalKeyboardKey.comma:
      return ',';
    case LogicalKeyboardKey.slash:
      return '/';
    case LogicalKeyboardKey.space:
      return 'Space';
    default:
      return key.debugName ?? '';
  }
}
