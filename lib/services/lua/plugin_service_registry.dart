import 'dart:async';

import 'lua_api_validator.dart';

class LuaServiceOverride {
  const LuaServiceOverride({
    required this.pluginId,
    required this.service,
    required this.operation,
    required this.handler,
    this.priority = 0,
  });

  final String pluginId;
  final String service;
  final String operation;

  /// VM 内由 Lua 注册时生成的稳定函数名。
  final String handler;
  final int priority;

  String get key => '$service.$operation';
}

typedef LuaOverrideExecutor = Future<Object?> Function(
  LuaServiceOverride override,
  Map<String, Object?> request,
  Future<Object?> Function(Map<String, Object?> request) next,
);

/// Dart 唯一服务入口；没有 Lua 覆盖时不会进入 FFI。
class PluginServiceRegistry {
  PluginServiceRegistry({
    LuaOverrideExecutor? executor,
    bool Function(String pluginId)? isEditorModifyGranted,
  }) : _executor = executor,
       _isEditorModifyGranted = isEditorModifyGranted ?? ((_) => false);

  static const maxChainDepth = 32;
  static const supportedOperations = {
    'editor': {'openFile', 'saveFile', 'applyEdit'},
    'completion': {'list'},
    'command': {'execute'},
    'ui': {'notify'},
  };

  LuaOverrideExecutor? _executor;
  final bool Function(String pluginId) _isEditorModifyGranted;
  final Map<String, List<LuaServiceOverride>> _overrides = {};
  int _generation = 0;

  int get generation => _generation;
  List<LuaServiceOverride> get overrides =>
      List.unmodifiable(_overrides.values.expand((items) => items));

  void setExecutor(LuaOverrideExecutor? executor) {
    _executor = executor;
    _generation++;
  }

  /// 将 Registry 的 next 回调映射到原生 VM 的挂起/恢复协议。
  void attachLuaBackend(
    Map<String, Object?> Function(
      String pluginId,
      String handler,
      Object? payload, {
      bool resume,
      bool isError,
    })
    backend,
  ) {
    setExecutor((override, request, next) async {
      final backendGeneration = _generation;
      final result = backend(override.pluginId, override.handler, request);
      if (result['status'] == 'done') return result['result'];
      final yielded = result['yield'];
      if (result['status'] != 'yield' ||
          yielded is! Map ||
          yielded['kind'] != 'next') {
        throw PluginServiceRegistryException('插件 ${override.pluginId} 返回了无效响应');
      }
      final nextRequest = yielded['payload'] ?? request;
      Object? nextResult;
      Object? nextError;
      try {
        nextResult = await next(_objectMap(nextRequest));
      } catch (error) {
        nextError = error;
      }
      if (backendGeneration != _generation) {
        throw const PluginGenerationChangedException();
      }
      final resumed = backend(
        override.pluginId,
        override.handler,
        nextError ?? nextResult,
        resume: true,
        isError: nextError != null,
      );
      if (backendGeneration != _generation) {
        throw const PluginGenerationChangedException();
      }
      if (resumed['status'] == 'done') return resumed['result'];
      throw PluginServiceRegistryException('插件 ${override.pluginId} 恢复执行失败');
    });
  }

  static Map<String, Object?> _objectMap(Object? value) {
    if (value is! Map) {
      throw const PluginServiceRegistryException('next 请求必须是对象');
    }
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  /// 原子重建注册表；权限检查在这里执行，而不是信任 Lua 的声明。
  void replaceAll(Iterable<LuaServiceOverride> replacements) {
    final grouped = <String, List<LuaServiceOverride>>{};
    for (final item in replacements) {
      final operations = supportedOperations[item.service];
      if (operations == null || !operations.contains(item.operation)) {
        throw PluginServiceRegistryException('未声明的服务：${item.key}');
      }
      if (!_isEditorModifyGranted(item.pluginId)) {
        throw PluginServiceRegistryException(
          '插件 ${item.pluginId} 未获 editor.modify 授权',
        );
      }
      if (item.handler.trim().isEmpty) {
        throw const PluginServiceRegistryException('Lua 覆盖缺少 handler');
      }
      grouped.putIfAbsent(item.key, () => []).add(item);
    }
    for (final entry in grouped.entries) {
      if (entry.value.length > maxChainDepth) {
        throw PluginServiceRegistryException('${entry.key} 的覆盖链超过 32 层');
      }
      entry.value.sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        return byPriority != 0 ? byPriority : a.pluginId.compareTo(b.pluginId);
      });
    }
    _overrides
      ..clear()
      ..addAll(grouped);
    _generation++;
  }

  void removePlugin(String pluginId) {
    for (final key in _overrides.keys.toList()) {
      final remaining = _overrides[key]!
          .where((item) => item.pluginId != pluginId)
          .toList();
      if (remaining.isEmpty) {
        _overrides.remove(key);
      } else {
        _overrides[key] = remaining;
      }
    }
    _generation++;
  }

  Future<Object?> invoke(
    String service,
    String operation,
    Map<String, Object?> request,
    Future<Object?> Function(Map<String, Object?> request) defaultHandler,
  ) async {
    LuaApiValidator.validateServiceRequest(service, operation, request);
    final chain = _overrides['$service.$operation'];
    if (chain == null || chain.isEmpty) {
      final result = await defaultHandler(request);
      LuaApiValidator.validateServiceResponse(service, operation, result);
      return result;
    }
    final executor = _executor;
    if (executor == null) {
      throw PluginServiceRegistryException('$service.$operation 的 Lua 运行时不可用');
    }
    final invocationGeneration = _generation;

    Future<Object?> callAt(int index, Map<String, Object?> currentRequest) {
      LuaApiValidator.validateServiceRequest(
        service,
        operation,
        currentRequest,
      );
      if (invocationGeneration != _generation) {
        throw const PluginGenerationChangedException();
      }
      if (index >= chain.length) return defaultHandler(currentRequest);
      final item = chain[index];
      if (!_isEditorModifyGranted(item.pluginId)) {
        throw PluginServiceRegistryException(
          '插件 ${item.pluginId} 的 editor.modify 授权已失效',
        );
      }
      var nextCalled = false;
      return executor(item, currentRequest, (nextRequest) {
        if (nextCalled) {
          throw PluginServiceRegistryException(
            '插件 ${item.pluginId} 对同一调用执行了多次 next',
          );
        }
        nextCalled = true;
        return callAt(index + 1, nextRequest);
      });
    }

    final result = await callAt(0, request);
    if (invocationGeneration != _generation) {
      throw const PluginGenerationChangedException();
    }
    LuaApiValidator.validateServiceResponse(service, operation, result);
    return result;
  }
}

class PluginServiceRegistryException implements Exception {
  const PluginServiceRegistryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PluginGenerationChangedException implements Exception {
  const PluginGenerationChangedException();

  @override
  String toString() => 'Lua 插件已重载，本次旧调用已取消';
}
