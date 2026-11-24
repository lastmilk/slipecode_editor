import 'dart:async';

enum PluginEventAction { continueEvent, modify, swallow }

class PluginEventResult {
  const PluginEventResult({required this.action, required this.event});

  final PluginEventAction action;
  final Map<String, Object?> event;

  bool get swallowed => action == PluginEventAction.swallow;
}

class LuaEventHook {
  const LuaEventHook({
    required this.pluginId,
    required this.type,
    required this.phase,
    required this.handler,
    this.priority = 0,
  });

  final String pluginId;
  final String type;
  final String phase;
  final String handler;
  final int priority;
}

typedef LuaEventExecutor = Future<Map<String, Object?>?> Function(
  LuaEventHook hook,
  Map<String, Object?> event,
);

typedef LuaSyncEventExecutor = Map<String, Object?>? Function(
  LuaEventHook hook,
  Map<String, Object?> event,
);

class PluginEventBus {
  PluginEventBus({
    LuaEventExecutor? executor,
    LuaSyncEventExecutor? syncExecutor,
    bool Function(String pluginId, String capability)? hasCapability,
    bool Function(String pluginId)? isEditorModifyGranted,
    void Function(LuaEventHook hook, Object error)? onError,
  }) : _executor = executor,
       _syncExecutor = syncExecutor,
       _hasCapability = hasCapability ?? ((_, _) => false),
       _isEditorModifyGranted = isEditorModifyGranted ?? ((_) => false),
       _onError = onError;

  static const eventPhases = {
    'file.willOpen': 'will',
    'file.didOpen': 'did',
    'file.willSave': 'will',
    'file.didSave': 'did',
    'command.willExecute': 'will',
    'command.didExecute': 'did',
    'editor.key': 'will',
  };

  LuaEventExecutor? _executor;
  LuaSyncEventExecutor? _syncExecutor;
  final bool Function(String pluginId, String capability) _hasCapability;
  final bool Function(String pluginId) _isEditorModifyGranted;
  final void Function(LuaEventHook hook, Object error)? _onError;
  final Map<String, List<LuaEventHook>> _hooks = {};
  int _generation = 0;

  int get generation => _generation;

  void setExecutor(LuaEventExecutor? executor) {
    _executor = executor;
    _generation++;
  }

  void setSyncExecutor(LuaSyncEventExecutor? executor) {
    _syncExecutor = executor;
    _generation++;
  }

  bool hasHooks(String type) => _hooks[type]?.isNotEmpty ?? false;

  void replaceAll(Iterable<LuaEventHook> replacements) {
    final grouped = <String, List<LuaEventHook>>{};
    for (final hook in replacements) {
      final expectedPhase = eventPhases[hook.type];
      if (expectedPhase == null || expectedPhase != hook.phase) {
        throw PluginEventException('未知事件或阶段：${hook.type}/${hook.phase}');
      }
      if (hook.phase == 'will') {
        if (!_isEditorModifyGranted(hook.pluginId)) {
          throw PluginEventException('插件 ${hook.pluginId} 未获修改/吞掉事件的授权');
        }
      } else if (!_hasCapability(hook.pluginId, 'events')) {
        throw PluginEventException('插件 ${hook.pluginId} 未声明 events 能力');
      }
      grouped.putIfAbsent(hook.type, () => []).add(hook);
    }
    for (final hooks in grouped.values) {
      hooks.sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        return byPriority != 0 ? byPriority : a.pluginId.compareTo(b.pluginId);
      });
    }
    _hooks
      ..clear()
      ..addAll(grouped);
    _generation++;
  }

  void removePlugin(String pluginId) {
    for (final key in _hooks.keys.toList()) {
      final remaining = _hooks[key]!
          .where((hook) => hook.pluginId != pluginId)
          .toList();
      if (remaining.isEmpty) {
        _hooks.remove(key);
      } else {
        _hooks[key] = remaining;
      }
    }
    _generation++;
  }

  /// 键盘事件在 Focus/Shortcut 分发前同步执行，禁止挂起协程或等待 Future。
  PluginEventResult dispatchSync(String type, Map<String, Object?> event) {
    if (type != 'editor.key') {
      throw PluginEventException('$type 不支持同步分发');
    }
    final hooks = _hooks[type];
    if (hooks == null || hooks.isEmpty) {
      return PluginEventResult(
        action: PluginEventAction.continueEvent,
        event: event,
      );
    }
    final executor = _syncExecutor;
    if (executor == null) {
      return PluginEventResult(
        action: PluginEventAction.continueEvent,
        event: event,
      );
    }
    var current = event;
    for (final hook in List<LuaEventHook>.of(hooks)) {
      try {
        final raw = executor(hook, current);
        if (raw == null) continue;
        final action = switch (raw['action']) {
          null || 'continue' => PluginEventAction.continueEvent,
          'modify' => PluginEventAction.modify,
          'swallow' => PluginEventAction.swallow,
          final value => throw PluginEventException('未知事件决策：$value'),
        };
        if (action == PluginEventAction.modify) {
          final changed = raw['event'];
          if (changed is! Map) {
            throw const PluginEventException('modify 决策缺少 event 对象');
          }
          current = changed.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          if (current['type'] != type || current['phase'] != hook.phase) {
            throw const PluginEventException('事件钩子不能修改 type 或 phase');
          }
        }
        if (action == PluginEventAction.swallow) {
          return PluginEventResult(action: action, event: current);
        }
      } catch (error) {
        // 键盘必须 fail-open；错误钩子立即失效，避免每次输入都重复失败。
        _hooks[type]?.removeWhere((item) => item == hook);
        _onError?.call(hook, error);
      }
    }
    return PluginEventResult(
      action: PluginEventAction.continueEvent,
      event: current,
    );
  }

  Future<PluginEventResult> dispatch(
    String type,
    Map<String, Object?> event, {
    bool failOpen = false,
  }) async {
    final hooks = _hooks[type];
    if (hooks == null || hooks.isEmpty) {
      return PluginEventResult(
        action: PluginEventAction.continueEvent,
        event: event,
      );
    }
    final executor = _executor;
    if (executor == null) {
      if (failOpen) {
        return PluginEventResult(
          action: PluginEventAction.continueEvent,
          event: event,
        );
      }
      throw PluginEventException('$type 的 Lua 运行时不可用');
    }
    var current = event;
    for (final hook in List<LuaEventHook>.of(hooks)) {
      try {
        final raw = await executor(hook, current);
        if (raw == null) continue;
        final action = switch (raw['action']) {
          null || 'continue' => PluginEventAction.continueEvent,
          'modify' => PluginEventAction.modify,
          'swallow' => PluginEventAction.swallow,
          final value => throw PluginEventException('未知事件决策：$value'),
        };
        if (hook.phase == 'did' && action != PluginEventAction.continueEvent) {
          throw const PluginEventException('did 阶段事件只读，不能修改或吞掉');
        }
        if (action == PluginEventAction.modify) {
          final changed = raw['event'];
          if (changed is! Map) {
            throw const PluginEventException('modify 决策缺少 event 对象');
          }
          current = changed.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          if (current['type'] != type || current['phase'] != hook.phase) {
            throw const PluginEventException('事件钩子不能修改 type 或 phase');
          }
        }
        if (action == PluginEventAction.swallow) {
          return PluginEventResult(action: action, event: current);
        }
      } catch (error) {
        if (!failOpen) rethrow;
        _hooks[type]?.removeWhere((item) => item.handler == hook.handler);
        _onError?.call(hook, error);
      }
    }
    return PluginEventResult(
      action: PluginEventAction.continueEvent,
      event: current,
    );
  }
}

class PluginEventException implements Exception {
  const PluginEventException(this.message);

  final String message;

  @override
  String toString() => message;
}
