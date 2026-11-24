import 'dart:ffi';
import 'dart:io';

final class SlipeLuaNativeLibrary {
  const SlipeLuaNativeLibrary._();

  static DynamicLibrary open([String? explicitPath]) {
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return DynamicLibrary.open(explicitPath);
    }

    final candidates = <String>{};
    final environmentPath = Platform.environment['SLIPE_LUA_LIBRARY'];
    if (environmentPath != null && environmentPath.isNotEmpty) {
      candidates.add(environmentPath);
    }

    final executable = File(Platform.resolvedExecutable).absolute;
    final executableDirectory = executable.parent.path;
    if (Platform.isLinux) {
      candidates.add('$executableDirectory/lib/libslipe_lua.so');
    } else if (Platform.isWindows) {
      candidates.add('$executableDirectory/slipe_lua.dll');
    } else if (Platform.isMacOS) {
      candidates.add('$executableDirectory/../Frameworks/libslipe_lua.dylib');
    }

    void addPackageCandidates(Directory directory) {
      var current = directory.absolute;
      for (var depth = 0; depth < 7; depth++) {
        if (Platform.isLinux) {
          candidates.add('${current.path}/build/linux/libslipe_lua.so');
          candidates.add(
            '${current.path}/packages/slipe_lua/build/linux/libslipe_lua.so',
          );
        } else if (Platform.isWindows) {
          candidates.add('${current.path}/build/windows/Release/slipe_lua.dll');
          candidates.add(
            '${current.path}/packages/slipe_lua/build/windows/Release/slipe_lua.dll',
          );
        } else if (Platform.isMacOS) {
          candidates.add('${current.path}/build/macos/libslipe_lua.dylib');
          candidates.add(
            '${current.path}/packages/slipe_lua/build/macos/libslipe_lua.dylib',
          );
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }

    addPackageCandidates(Directory.current);
    if (Platform.script.isScheme('file')) {
      addPackageCandidates(File(Platform.script.toFilePath()).parent);
    }

    final errors = <String>[];
    for (final candidate in candidates) {
      if (!File(candidate).existsSync()) continue;
      try {
        return DynamicLibrary.open(candidate);
      } catch (error) {
        errors.add('$candidate: $error');
      }
    }
    throw StateError(
      'Unable to locate the slipe_lua native library. Build the package for '
      'this desktop platform or set SLIPE_LUA_LIBRARY to its full path. '
      'Searched ${candidates.length} locations.'
      '${errors.isEmpty ? '' : ' Errors: ${errors.join('; ')}'}',
    );
  }
}
