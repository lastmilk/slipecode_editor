import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_library.dart';
import 'slipe_lua_exception.dart';

final class SlipeLuaVmHandle extends Opaque {}

typedef _CreateNative = Pointer<SlipeLuaVmHandle> Function(
  Pointer<Utf8>,
  Uint64,
  Pointer<Pointer<Utf8>>,
);
typedef _CreateDart = Pointer<SlipeLuaVmHandle> Function(
  Pointer<Utf8>,
  int,
  Pointer<Pointer<Utf8>>,
);
typedef _ExecNative = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint64,
);
typedef _ExecDart = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
);
typedef _SnapshotNative = Pointer<Utf8> Function(Pointer<SlipeLuaVmHandle>);
typedef _SnapshotDart = Pointer<Utf8> Function(Pointer<SlipeLuaVmHandle>);
typedef _InvokeNative = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint64,
);
typedef _InvokeDart = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
);
typedef _ResumeNative = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  Int32,
  Uint64,
);
typedef _ResumeDart = Pointer<Utf8> Function(
  Pointer<SlipeLuaVmHandle>,
  Pointer<Utf8>,
  int,
  int,
);
typedef _DestroyNative = Void Function(Pointer<SlipeLuaVmHandle>);
typedef _DestroyDart = void Function(Pointer<SlipeLuaVmHandle>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final class SlipeLuaBindings {
  SlipeLuaBindings.open([String? libraryPath])
      : _library = SlipeLuaNativeLibrary.open(libraryPath) {
    _create = _library.lookupFunction<_CreateNative, _CreateDart>(
      'slipe_lua_create',
    );
    _exec = _library.lookupFunction<_ExecNative, _ExecDart>('slipe_lua_exec');
    _snapshot = _library.lookupFunction<_SnapshotNative, _SnapshotDart>(
      'slipe_lua_snapshot',
    );
    _invoke = _library.lookupFunction<_InvokeNative, _InvokeDart>(
      'slipe_lua_invoke',
    );
    _resume = _library.lookupFunction<_ResumeNative, _ResumeDart>(
      'slipe_lua_resume',
    );
    _destroy = _library.lookupFunction<_DestroyNative, _DestroyDart>(
      'slipe_lua_destroy',
    );
    _free = _library.lookupFunction<_FreeNative, _FreeDart>('slipe_lua_free');
  }

  final DynamicLibrary _library;
  late final _CreateDart _create;
  late final _ExecDart _exec;
  late final _SnapshotDart _snapshot;
  late final _InvokeDart _invoke;
  late final _ResumeDart _resume;
  late final _DestroyDart _destroy;
  late final _FreeDart _free;

  Pointer<SlipeLuaVmHandle> create(String pluginRoot, int memoryLimit) {
    return using((arena) {
      final error = arena<Pointer<Utf8>>();
      final handle = _create(
        pluginRoot.toNativeUtf8(allocator: arena),
        memoryLimit,
        error,
      );
      if (handle == nullptr) {
        final message = error.value == nullptr
            ? 'Unable to create Lua VM'
            : _takeString(error.value);
        throw SlipeLuaException(message);
      }
      return handle;
    });
  }

  String exec(
    Pointer<SlipeLuaVmHandle> handle,
    String source,
    String chunkName,
    int budget,
  ) {
    return using((arena) {
      return _takeString(
        _exec(
          handle,
          source.toNativeUtf8(allocator: arena),
          chunkName.toNativeUtf8(allocator: arena),
          budget,
        ),
      );
    });
  }

  String snapshot(Pointer<SlipeLuaVmHandle> handle) =>
      _takeString(_snapshot(handle));

  String invoke(
    Pointer<SlipeLuaVmHandle> handle,
    String handler,
    String payload,
    int budget,
  ) {
    return using((arena) {
      return _takeString(
        _invoke(
          handle,
          handler.toNativeUtf8(allocator: arena),
          payload.toNativeUtf8(allocator: arena),
          budget,
        ),
      );
    });
  }

  String resume(
    Pointer<SlipeLuaVmHandle> handle,
    String payload,
    bool isError,
    int budget,
  ) {
    return using((arena) {
      return _takeString(
        _resume(
          handle,
          payload.toNativeUtf8(allocator: arena),
          isError ? 1 : 0,
          budget,
        ),
      );
    });
  }

  void destroy(Pointer<SlipeLuaVmHandle> handle) => _destroy(handle);

  String _takeString(Pointer<Utf8> pointer) {
    if (pointer == nullptr) {
      throw const SlipeLuaException('Native library returned no result');
    }
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer.cast());
    }
  }
}
