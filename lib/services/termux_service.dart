import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Termux 构建环境服务
///
/// 核心原理：通过 Termux:API 提供的 RunCommandService 在 Termux 环境中执行命令。
/// Android 端通过 Intent 启动 com.termux.app.RunCommandService，
/// 把命令交给 Termux 的 bash 执行，输出重定向到文件后再读回。
///
/// 前置条件：
/// 1. 已安装 Termux（com.termux）
/// 2. 已安装 Termux:API（com.termux.api）
/// 3. 已在 Termux 中安装 flutter / java / gradle 等构建工具
class TermuxService {
  TermuxService._();

  static final TermuxService instance = TermuxService._();

  static const MethodChannel _channel = MethodChannel('slipecode/termux');

  /// 检查 Termux 是否已安装
  Future<bool> isTermuxInstalled() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isTermuxInstalled');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 检查 Termux:API 是否已安装
  Future<bool> isTermuxApiInstalled() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isTermuxApiInstalled');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 检查 Termux 中是否安装了 flutter
  Future<bool> hasFlutter() async {
    final result = await exec('which flutter');
    return result.exitCode == 0 && result.stdout.trim().isNotEmpty;
  }

  /// 检查 Termux 中是否安装了 java
  Future<bool> hasJava() async {
    final result = await exec('java -version');
    return result.exitCode == 0;
  }

  /// 执行单条命令并返回结果
  ///
  /// [command] 要在 Termux bash 中执行的命令
  /// [workDir] 工作目录（Termux 内的绝对路径，如 /data/data/com.termux/files/home/project）
  Future<TermuxExecResult> exec(
    String command, {
    String? workDir,
  }) async {
    try {
      final args = <String, dynamic>{'command': command};
      if (workDir != null) args['workDir'] = workDir;
      final result = await _channel.invokeMethod<Map>('exec', args);
      return TermuxExecResult(
        exitCode: (result?['exitCode'] as num?)?.toInt() ?? -1,
        stdout: (result?['stdout'] as String?) ?? '',
        stderr: (result?['stderr'] as String?) ?? '',
      );
    } catch (e) {
      return TermuxExecResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Termux 调用失败：$e',
      );
    }
  }

  /// 把项目目录复制/挂载到 Termux 可访问的位置
  ///
  /// 由于 Android 沙箱限制，Termux 无法直接访问应用私有目录。
  /// 这里把项目软链或复制到 Termux 的 home 目录下。
  Future<String?> prepareProject(String projectPath) async {
    final home = '/data/data/com.termux/files/home';
    final name = p.basename(projectPath);
    final target = '$home/slipecode_$name';

    // 先清理旧的
    await exec('rm -rf "$target"');

    // 用 cp -a 复制整个项目（Termux 有读取外部存储权限时也可直接用 ln -s）
    final result = await exec('cp -a "$projectPath" "$target"');
    if (result.exitCode != 0) {
      // 尝试用软链（需要 Termux 有存储权限）
      final linkResult = await exec('ln -s "$projectPath" "$target"');
      if (linkResult.exitCode != 0) return null;
    }
    return target;
  }

  /// 在 Termux 中执行 Flutter 构建
  ///
  /// [projectDir] 已准备好的 Termux 内项目路径
  /// [buildType] 构建类型：apk-release / apk-debug / appbundle
  /// [onLog] 实时日志回调
  Future<TermuxExecResult> flutterBuild(
    String projectDir,
    String buildType, {
    void Function(String line)? onLog,
  }) async {
    final buildCmd = switch (buildType) {
      'apk-debug' => 'flutter build apk --debug',
      'appbundle-release' => 'flutter build appbundle --release',
      _ => 'flutter build apk --release',
    };

    // 组合命令：pub get + 构建，输出同时写入文件以便读取
    final script =
        'cd "$projectDir" && flutter pub get 2>&1 && $buildCmd 2>&1';

    onLog?.call('==> 在 Termux 中执行：$buildCmd');
    final result = await exec(script);
    if (result.stdout.isNotEmpty) onLog?.call(result.stdout);
    if (result.stderr.isNotEmpty) onLog?.call(result.stderr);
    return result;
  }

  /// 查找构建产物路径
  Future<String?> findArtifact(String projectDir, String buildType) async {
    final pattern = switch (buildType) {
      'apk-debug' => 'build/app/outputs/flutter-apk/app-debug.apk',
      'appbundle-release' =>
        'build/app/outputs/bundle/release/app-release.aab',
      _ => 'build/app/outputs/flutter-apk/app-release.apk',
    };
    final result = await exec('ls "$projectDir/$pattern"');
    if (result.exitCode == 0) {
      return result.stdout.trim();
    }
    return null;
  }

  /// 把 Termux 中的构建产物复制回应用可访问目录
  Future<String?> copyArtifactToApp(String termuxPath, String projectDir) async {
    final support = await getApplicationSupportDirectory();
    final outDir = Directory(p.join(support.path, 'termux_builds'));
    await outDir.create(recursive: true);
    final name = p.basename(termuxPath);
    final outPath = p.join(outDir.path, name);

    final result = await exec('cp "$termuxPath" "$outPath"');
    if (result.exitCode != 0) return null;
    return outPath;
  }

  /// 清理 Termux 中的临时项目
  Future<void> cleanup(String termuxProjectPath) async {
    await exec('rm -rf "$termuxProjectPath"');
  }
}

/// Termux 命令执行结果
class TermuxExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const TermuxExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  bool get isSuccess => exitCode == 0;
}
