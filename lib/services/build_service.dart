import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'github_actions_templates.dart';
import 'github_api_service.dart';

/// 构建类型（对应 workflow_dispatch 的 build_type 输入）
enum BuildType {
  apkRelease('apk-release', 'APK (Release)', '.apk'),
  apkDebug('apk-debug', 'APK (Debug)', '.apk'),
  appBundleRelease('appbundle-release', 'AppBundle (Release)', '.aab'),

  /// iOS 构建需要 macOS Runner；Gitee Go 不支持，只能在 GitHub 上执行。
  /// 证书暂未配置，使用 `--no-codesign` 产出未签名的 Runner.app（zip）。
  iosRelease('ios-release', 'iOS (无签名)', '.app');

  /// workflow inputs.build_type 取值
  final String inputValue;
  final String label;

  /// 产物扩展名
  final String artifactExt;

  const BuildType(this.inputValue, this.label, this.artifactExt);

  bool get isIos => this == BuildType.iosRelease;

  /// Gitee Go 可用的构建类型（无 macOS Runner）
  static List<BuildType> forHost({required bool supportsIos}) =>
      values.where((t) => supportsIos || !t.isIos).toList();
}

/// GitHub Actions 构建服务
///
/// 构建流程：
/// 1. 确保仓库中存在构建 workflow（不存在则推送）
/// 2. workflow_dispatch 触发构建
/// 3. 轮询运行状态直到完成
/// 4. 下载并解压构建产物
class BuildService {
  BuildService._();

  static final BuildService instance = BuildService._();

  static const MethodChannel _channel = MethodChannel('slipecode/container');

  static const String workflowFile = GitHubActionsTemplates.workflowPath;

  /// 确保仓库中存在构建 workflow，缺失时自动推送
  Future<void> ensureWorkflow(
    GitHubApiService api,
    String repoFullName, {
    String branch = 'main',
  }) async {
    final exists = await api.fileExists(repoFullName, workflowFile, branch);
    if (exists) return;
    await api.pushFiles(
      repoFullName,
      [
        RepoFile(
          workflowFile,
          Uint8List.fromList(utf8.encode(GitHubActionsTemplates.flutterBuildWorkflow)),
        ),
      ],
      message: 'ci: add SLIPE build workflow',
      branch: branch,
    );
  }

  /// 触发一次 workflow_dispatch 构建，返回触发时间（用于定位新运行）
  Future<DateTime> dispatch(
    GitHubApiService api,
    String repoFullName,
    BuildType type, {
    String branch = 'main',
  }) async {
    final triggeredAt = DateTime.now();
    await api.dispatchWorkflow(
      repoFullName,
      workflowFile,
      ref: branch,
      inputs: {'build_type': type.inputValue},
    );
    return triggeredAt;
  }

  /// 等待触发后出现的新运行并轮询至完成。
  ///
  /// [onUpdate] 每次状态变化时回调（用于日志）。
  /// [isCancelled] 返回 true 时抛出 [_CancelledError]。
  Future<WorkflowRun> waitForCompletion(
    GitHubApiService api,
    String repoFullName,
    DateTime triggeredAt, {
    String branch = 'main',
    void Function(WorkflowRun run)? onUpdate,
    bool Function()? isCancelled,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);

    // 等待 GitHub 生成 run 记录
    WorkflowRun? run;
    while (run == null) {
      _throwIfCancelled(isCancelled);
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('等待构建运行创建超时');
      }
      await Future.delayed(const Duration(seconds: 3));
      run = await api.latestRunSince(
        repoFullName,
        workflowFile,
        triggeredAt,
        branch: branch,
      );
    }
    onUpdate?.call(run);

    // 轮询至完成
    var lastStatus = run.status;
    while (!run!.isCompleted) {
      _throwIfCancelled(isCancelled);
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('构建超时（>${timeout.inMinutes} 分钟）');
      }
      await Future.delayed(const Duration(seconds: 5));
      run = await api.getRun(repoFullName, run.id);
      if (run.status != lastStatus) {
        lastStatus = run.status;
        onUpdate?.call(run);
      }
    }
    return run;
  }

  /// 下载产物 zip 并解压出 APK/AAB 到 `项目目录/build/github/`
  ///
  /// iOS 产物是未签名的 Runner.app 目录，直接保存原始 zip。
  Future<String?> downloadAndExtractArtifact(
    GitHubApiService api,
    String repoFullName,
    RunArtifact artifact,
    String projectDir,
    BuildType type,
  ) async {
    final zipBytes = await api.downloadArtifact(repoFullName, artifact.id);

    final outDir = Directory(p.join(projectDir, 'build', 'github'));
    await outDir.create(recursive: true);

    if (type.isIos) {
      final outPath = p.join(outDir.path, 'slipecode-ios-unsigned.zip');
      await File(outPath).writeAsBytes(zipBytes, flush: true);
      return outPath;
    }

    final archive = ZipDecoder().decodeBytes(zipBytes);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = p.basename(entry.name);
      if (!name.toLowerCase().endsWith(type.artifactExt)) continue;
      final outPath = p.join(outDir.path, name);
      final bytes = Uint8List.fromList(entry.content as List<int>);
      await File(outPath).writeAsBytes(bytes, flush: true);
      return outPath;
    }
    return null;
  }

  /// 通过系统安装器安装 APK
  Future<bool> installApk(String apkPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('installApk', {'path': apkPath});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() == true) {
      throw const _CancelledError();
    }
  }
}

class _CancelledError implements Exception {
  const _CancelledError();

  @override
  String toString() => '已取消';
}
