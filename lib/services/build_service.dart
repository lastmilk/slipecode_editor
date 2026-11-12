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
  iosRelease('ios-release', 'iOS (无签名)', '.app'),

  /// 通用产物（Node.js / HTML / Taro 等非移动端载荷）。
  /// workflow 直接上传构建目录，产物为 zip。
  generic('release', '构建产物', '.zip');

  /// workflow inputs.build_type 取值
  final String inputValue;
  final String label;

  /// 产物扩展名
  final String artifactExt;

  const BuildType(this.inputValue, this.label, this.artifactExt);

  bool get isIos => this == BuildType.iosRelease;

  /// 是否直接保存原始 zip（不解压寻找产物文件）
  bool get savesRawZip => isIos || this == BuildType.generic;

  /// 按 workflow_dispatch 的 build_type 取值查找构建类型
  static BuildType? byInput(String id) {
    for (final type in values) {
      if (type.inputValue == id) return type;
    }
    return null;
  }

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

  static const MethodChannel _channel = MethodChannel('slipe/container');

  static const String workflowFile = GitHubActionsTemplates.workflowPath;

  /// 确保仓库中存在构建 workflow，缺失时自动推送。
  ///
  /// [path] / [content] 由项目载荷（Payload）决定。
  Future<void> ensureWorkflow(
    GitHubApiService api,
    String repoFullName, {
    String branch = 'main',
    String path = GitHubActionsTemplates.workflowPath,
    String content = GitHubActionsTemplates.flutterBuildWorkflow,
  }) async {
    final exists = await api.fileExists(repoFullName, path, branch);
    if (exists) return;
    await api.pushFiles(
      repoFullName,
      [RepoFile(path, Uint8List.fromList(utf8.encode(content)))],
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
    String path = GitHubActionsTemplates.workflowPath,
  }) async {
    final triggeredAt = DateTime.now();
    await api.dispatchWorkflow(
      repoFullName,
      path,
      ref: branch,
      inputs: {'build_type': type.inputValue},
    );
    return triggeredAt;
  }

  /// 等待 GitHub 为新触发的构建创建运行记录（不等待完成）
  Future<WorkflowRun> waitForRunStarted(
    GitHubApiService api,
    String repoFullName,
    DateTime triggeredAt, {
    String branch = 'main',
    bool Function()? isCancelled,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
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
    return run;
  }

  /// 等待触发后出现的新运行并轮询至完成。
  ///
  /// [onUpdate] 每次运行状态变化时回调（用于日志）。
  /// [onJobs] 每次轮询都回调 Job / 步骤列表（用于展示完整构建流程）。
  /// [isCancelled] 返回 true 时抛出 [_CancelledError]。
  Future<WorkflowRun> waitForCompletion(
    GitHubApiService api,
    String repoFullName,
    DateTime triggeredAt, {
    String branch = 'main',
    void Function(WorkflowRun run)? onUpdate,
    void Function(List<WorkflowJob> jobs)? onJobs,
    bool Function()? isCancelled,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);

    // 等待 GitHub 生成 run 记录
    final run = await waitForRunStarted(
      api,
      repoFullName,
      triggeredAt,
      branch: branch,
      isCancelled: isCancelled,
    );
    onUpdate?.call(run);

    // 轮询至完成（同时刷新 Job / 步骤进度）
    var current = run;
    var lastStatus = current.status;
    var jobsFetched = false;
    while (!current.isCompleted) {
      _throwIfCancelled(isCancelled);
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('构建超时（>${timeout.inMinutes} 分钟）');
      }
      await Future.delayed(const Duration(seconds: 4));
      current = await api.getRun(repoFullName, current.id);
      if (current.status != lastStatus) {
        lastStatus = current.status;
        onUpdate?.call(current);
      }
      if (onJobs != null) {
        try {
          onJobs(await api.listJobs(repoFullName, current.id));
          jobsFetched = true;
        } catch (_) {
          // 步骤接口偶发失败不影响整体轮询
        }
      }
    }
    if (onJobs != null && !jobsFetched) {
      try {
        onJobs(await api.listJobs(repoFullName, current.id));
      } catch (_) {}
    }
    return current;
  }

  /// 下载产物 zip 并解压出 APK/AAB 到 `项目目录/build/github/`
  ///
  /// iOS 产物是未签名的 Runner.app 目录，通用载荷（Node/HTML/Taro）是
  /// 构建目录，二者都直接保存原始 zip。
  Future<String?> downloadAndExtractArtifact(
    GitHubApiService api,
    String repoFullName,
    RunArtifact artifact,
    String projectDir,
    BuildType type,
  ) async {
    final zipBytes = await api.downloadArtifact(repoFullName, artifact.id);
    return saveArtifactZip(zipBytes, projectDir, type);
  }

  /// 把产物 zip 字节保存 / 解压到 `项目目录/build/github/`
  ///
  /// 服务端中转下载与直接下载共用该实现。
  Future<String?> saveArtifactZip(
    Uint8List zipBytes,
    String projectDir,
    BuildType type,
  ) async {
    final outDir = Directory(p.join(projectDir, 'build', 'github'));
    await outDir.create(recursive: true);

    if (type.savesRawZip) {
      final suffix = type.isIos
          ? 'ios-unsigned'
          : '${type.inputValue}-artifacts';
      final outPath = p.join(outDir.path, 'slipe-$suffix.zip');
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

  /// 用系统文件管理器 / 安装器打开构建产物
  ///
  /// 不再尝试静默安装：交给系统处理（APK 会进入安装器，其余类型由
  /// 文件管理器选择打开方式）。
  Future<bool> openArtifact(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('openFile', {
        'path': path,
        'mime': path.toLowerCase().endsWith('.apk')
            ? 'application/vnd.android.package-archive'
            : '*/*',
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 通过系统安装器安装 APK（保留旧接口，等价于 [openArtifact]）
  Future<bool> installApk(String apkPath) => openArtifact(apkPath);

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
