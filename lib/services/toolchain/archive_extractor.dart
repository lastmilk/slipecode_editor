import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'toolchain_models.dart';

/// 归档解压（tar.xz / tar.gz / tgz / zip）。
///
/// POSIX 使用系统 `tar`；Windows 优先使用系统自带 `tar.exe`（bsdtar），
/// 失败时退回 PowerShell `Expand-Archive`。解压后统一归一化到内容根目录。
class ArchiveExtractor {
  const ArchiveExtractor();

  /// 解压 [archive] 到 [destDir]，返回真正的内容根目录
  /// （压缩包内若只有单层目录，会自动下钻一层）。
  Future<Directory> extract({
    required File archive,
    required Directory destDir,
    required ToolchainCancelToken cancelToken,
  }) async {
    await destDir.create(recursive: true);
    cancelToken.throwIfCancelled();
    final lower = archive.path.toLowerCase();
    if (lower.endsWith('.zip')) {
      await _extractZip(archive, destDir);
    } else {
      await _extractTar(archive, destDir);
    }
    cancelToken.throwIfCancelled();
    final root = await _normalizeRoot(destDir);
    await _ensureExecutable(root);
    return root;
  }

  Future<void> _extractTar(File archive, Directory destDir) async {
    final executable = Platform.isWindows
        ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
            r'\System32\tar.exe'
        : 'tar';
    final result = await _run(executable, [
      '-xf',
      archive.path,
      '-C',
      destDir.path,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        const ['-xf'],
        '解压失败：${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  Future<void> _extractZip(File archive, Directory destDir) async {
    if (Platform.isWindows) {
      // Windows 自带 tar 对 zip 支持有限，直接用 PowerShell
      final result = await _run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath "${archive.path}" '
            '-DestinationPath "${destDir.path}" -Force',
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'powershell.exe',
          const ['Expand-Archive'],
          '解压失败：${result.stderr}'.trim(),
          result.exitCode,
        );
      }
      return;
    }
    final result = await _run('unzip', ['-q', '-o', archive.path, '-d', destDir.path]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'unzip',
        const ['-q'],
        '解压失败：${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  Future<Directory> _normalizeRoot(Directory destDir) async {
    final entries = await destDir.list().toList();
    final directories = entries.whereType<Directory>().toList();
    final hasFiles = entries.any((entity) => entity is File);
    if (!hasFiles && directories.length == 1) {
      return directories.first;
    }
    return destDir;
  }

  /// 解压工具（tar / unzip）通常会保留权限位，但部分镜像打包时会丢失，
  /// 这里对 bin 目录补一次可执行位。
  Future<void> _ensureExecutable(Directory root) async {
    if (Platform.isWindows) return;
    final bin = Directory('${root.path}${Platform.pathSeparator}bin');
    if (!await bin.exists()) return;
    try {
      await _run('chmod', ['-R', 'a+x', bin.path]);
    } catch (e) {
      // 权限修正失败不阻断安装，后续冒烟测试会暴露问题
      debugPrint('补可执行位失败：$e');
    }
  }

  Future<ProcessResult> _run(String executable, List<String> args) async {
    try {
      return await Process.run(executable, args)
          .timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw ProcessException(executable, args, '命令超时');
    }
  }
}
