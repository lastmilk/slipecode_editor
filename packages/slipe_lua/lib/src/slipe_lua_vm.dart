import 'dart:convert';
import 'dart:ffi';

import 'bindings.dart';
import 'slipe_lua_exception.dart';

final class SlipeLuaVm {
  SlipeLuaVm._(this._bindings, this._handle);

  factory SlipeLuaVm.open({
    required String pluginRoot,
    int memoryLimit = defaultMemoryLimit,
    String? libraryPath,
  }) {
    if (memoryLimit <= 0) {
      throw ArgumentError.value(memoryLimit, 'memoryLimit', 'Must be positive');
    }
    final bindings = SlipeLuaBindings.open(libraryPath);
    return SlipeLuaVm._(bindings, bindings.create(pluginRoot, memoryLimit));
  }

  static const int defaultMemoryLimit = 32 * 1024 * 1024;
  static const int defaultInstructionBudget = 200000;

  final SlipeLuaBindings _bindings;
  Pointer<SlipeLuaVmHandle>? _handle;

  bool get isDisposed => _handle == null;

  Map<String, Object?> exec(
    String source, {
    String chunkName = '=slipe',
    int instructionBudget = defaultInstructionBudget,
  }) {
    _checkBudget(instructionBudget);
    return _decodeResponse(
      _bindings.exec(_requireHandle(), source, chunkName, instructionBudget),
    );
  }

  Map<String, Object?> snapshot() {
    final decoded = jsonDecode(_bindings.snapshot(_requireHandle()));
    final map = _asMap(decoded, 'snapshot');
    _throwIfError(map);
    return map;
  }

  Map<String, Object?> invoke(
    String handler,
    Object? payload, {
    int instructionBudget = defaultInstructionBudget,
  }) {
    _checkBudget(instructionBudget);
    return _decodeResponse(
      _bindings.invoke(
        _requireHandle(),
        handler,
        jsonEncode(payload),
        instructionBudget,
      ),
    );
  }

  Map<String, Object?> resume(
    Object? payload, {
    bool isError = false,
    int instructionBudget = defaultInstructionBudget,
  }) {
    _checkBudget(instructionBudget);
    return _decodeResponse(
      _bindings.resume(
        _requireHandle(),
        jsonEncode(payload),
        isError,
        instructionBudget,
      ),
    );
  }

  void dispose() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    _bindings.destroy(handle);
  }

  void close() => dispose();

  Pointer<SlipeLuaVmHandle> _requireHandle() {
    final handle = _handle;
    if (handle == null) {
      throw StateError('SlipeLuaVm has already been disposed');
    }
    return handle;
  }

  static void _checkBudget(int budget) {
    if (budget <= 0) {
      throw ArgumentError.value(
        budget,
        'instructionBudget',
        'Must be positive',
      );
    }
  }

  static Map<String, Object?> _decodeResponse(String json) {
    final response = _asMap(jsonDecode(json), 'response');
    _throwIfError(response);
    final status = response['status'];
    if (status != 'done' && status != 'yield') {
      throw SlipeLuaException(
        'Native library returned an invalid status',
        response: response,
      );
    }
    return response;
  }

  static Map<String, Object?> _asMap(Object? value, String label) {
    if (value is! Map) {
      throw SlipeLuaException('Native $label is not a JSON object');
    }
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static void _throwIfError(Map<String, Object?> response) {
    if (response['status'] != 'error') return;
    final error = response['error'];
    final message = error is Map ? error['message'] : null;
    throw SlipeLuaException(
      message is String ? message : 'Unknown Lua error',
      response: response,
    );
  }
}
