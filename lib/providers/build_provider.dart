import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../payloads/project_payload.dart';
import '../services/build_notification_service.dart';
import '../services/build_service.dart';
import '../services/build_watch_service.dart';
import '../services/git_host.dart';
import '../services/gitee_go_templates.dart';
import '../services/github_api_service.dart'
    show RepoFile, RunArtifact, WorkflowJob, WorkflowRun;
import 'account_provider.dart';
import 'git_sync_provider.dart';
import 'gitee_provider.dart';
import 'github_provider.dart';
import 'project_provider.dart';
import 'settings_provider.dart';

/// 构建状态
enum BuildStatus { idle, running, success, failed, cancelled }

/// 构建状态管理（云端构建）
///
/// - GitHub：GitHub Actions（Android + iOS macOS Runner）
/// - Gitee：Gitee Go（仅 Android；Gitee Go 无 macOS Runner）
///
/// GitHub 流程：同步代码 → 确保 workflow → dispatch → 轮询 → 下载产物。
/// 登录用户额外把监听注册到服务端：退出构建页 / 退出 IDE 后仍由服务端
/// 持续同步进度，构建产物可先下发到服务端再由客户端下载。
class BuildProvider extends ChangeNotifier {
  BuildProvider(
    this._github,
    this._gitee,
    this._gitSync, [
    this._project,
    this._account,
    this._settings,
  ]);

  final GitHubProvider _github;
  final GiteeProvider _gitee;
  final GitSyncProvider _gitSync;

  /// 用于读取当前项目的载荷（模板 / workflow / 构建类型）
  final ProjectProvider? _project;

  /// 账号（登录后把构建监听交给服务端）
  final AccountProvider? _account;

  /// 偏好设置（自动下载 / 服务端中转开关）
  final SettingsProvider? _settings;

  /// 当前项目载荷，未打开项目时退回默认载荷
  ProjectPayload get payload => _project?.payload ?? PayloadRegistry.fallback;

  BuildStatus _status = BuildStatus.idle;
  BuildType _type = BuildType.apkRelease;

  final List<String> _logs = [];
  String? _artifactPath;
  String _error = '';
  String _currentTask = '';
  String _runUrl = '';

  /// 当前运行的 workflow job / step 列表（用于展示完整构建流程）
  List<WorkflowJob> _jobs = const [];

  /// GitHub Actions run id（取消工作流 / 服务端监听需要）
  int? _runId;

  /// 服务端监听记录 id
  String _watchId = '';

  DateTime? _startedAt;
  DateTime? _finishedAt;
  bool _cancelRequested = false;
  bool _disposed = false;

  BuildStatus get status => _status;

  /// 当前构建类型（当前载荷不支持时自动回退到第一个可用类型）
  BuildType get type {
    final types = availableTypes;
    if (types.isEmpty || types.contains(_type)) return _type;
    return types.first;
  }

  List<String> get logs => List.unmodifiable(_logs);
  String? get artifactPath => _artifactPath;
  String get error => _error;
  String get currentTask => _currentTask;
  String get runUrl => _runUrl;
  List<WorkflowJob> get jobs => List.unmodifiable(_jobs);
  int? get runId => _runId;
  DateTime? get startedAt => _startedAt;
  DateTime? get finishedAt => _finishedAt;

  bool get isRunning => _status == BuildStatus.running;

  /// 当前项目关联的平台
  GitHost? get host => _gitSync.currentLink?.host;

  /// 当前平台可选的构建类型
  ///
  /// 由项目载荷（Payload）声明，再按代码托管平台能力过滤。
  List<BuildType> get availableTypes {
    final types = payload.buildTypes
        .map((t) => BuildType.byInput(t.id))
        .whereType<BuildType>()
        .toList();
    if (types.isEmpty) return const [];
    return switch (host) {
      // Gitee Go 只有 Flutter 流水线，且没有 macOS Runner
      GitHost.gitee =>
        payload.supportsGitee
            ? types.where((t) => !t.isIos).toList()
            : const [],
      GitHost.github => types,
      null => types,
    };
  }

  Duration? get duration {
    if (_startedAt == null) return null;
    return (_finishedAt ?? DateTime.now()).difference(_startedAt!);
  }

  void setType(BuildType type) {
    if (isRunning) return;
    if (!availableTypes.contains(type)) return;
    _type = type;
    notifyListeners();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _append(String line) {
    if (line.isEmpty) return;
    _logs.add(line);
    if (_logs.length > 4000) {
      _logs.removeRange(0, _logs.length - 4000);
    }
    _safeNotify();
  }

  void _reset() {
    _logs.clear();
    _artifactPath = null;
    _error = '';
    _runUrl = '';
    _jobs = const [];
    _runId = null;
    _watchId = '';
    _startedAt = DateTime.now();
    _finishedAt = null;
    _cancelRequested = false;
    _safeNotify();
  }

  /// 切换项目时重置构建状态（保留正在进行的构建，避免丢失监听）
  void resetForProject() {
    if (isRunning) return;
    _status = BuildStatus.idle;
    _logs.clear();
    _jobs = const [];
    _artifactPath = null;
    _error = '';
    _runUrl = '';
    _currentTask = '';
    _runId = null;
    _watchId = '';
    _startedAt = null;
    _finishedAt = null;
    _cancelRequested = false;
    unawaited(BuildNotificationService.instance.stop());
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // 构建流程
  // ---------------------------------------------------------------------------

  /// 开始云端构建
  Future<void> startBuild({required String projectDir}) async {
    if (isRunning) return;

    // 合规：未同意《用户协议》与《隐私政策》→ 受限模式，云端构建不可用
    if (_settings?.settings.policyAcceptedVersion.isEmpty ?? false) {
      _fail('请先在首屏同意《用户协议》与《隐私政策》后再使用云端构建');
      return;
    }

    final link = _gitSync.currentLink;
    if (link == null) {
      _status = BuildStatus.failed;
      _error = '项目未关联远程仓库';
      _append('==> 失败：$_error');
      _safeNotify();
      return;
    }
    final host = link.host;
    final types = availableTypes;
    if (types.isEmpty) {
      _fail('当前项目载荷（${payload.name}）在 ${host.ciName} 上没有可用的构建类型');
      return;
    }
    if (!types.contains(_type)) {
      _type = types.first;
    }
    if (host == GitHost.gitee && !payload.supportsGitee) {
      _fail('${payload.name} 项目暂不支持 Gitee Go 构建，请使用 GitHub');
      return;
    }
    if (host == GitHost.gitee && !_gitee.isSignedIn) {
      _fail('尚未登录 Gitee');
      return;
    }
    if (host == GitHost.github && !_github.isSignedIn) {
      _fail('尚未登录 GitHub');
      return;
    }
    if (host == GitHost.gitee && _type.isIos) {
      _fail('Gitee Go 没有 macOS Runner，iOS 构建请使用 GitHub');
      return;
    }

    _status = BuildStatus.running;
    _currentTask = '云端构建 ${_type.label}';
    _reset();
    _append('==> 开始构建 ${_type.label}（${host.ciName}）');

    // 构建期间启动前台服务 + 常驻通知，避免退到后台后进程被回收
    await _startKeepAlive('正在准备云端构建');

    try {
      // 1. 同步本地未提交改动
      _currentTask = '同步本地改动';
      _append('==> 同步本地改动到 ${link.repo}');
      if (_gitSync.pendingCount > 0) {
        _append('    待同步文件：${_gitSync.pendingCount} 个');
        final ok = await _gitSync.syncNow();
        if (!ok) throw StateError('同步失败：${_gitSync.error ?? '未知错误'}');
      } else {
        _append('    无待同步改动');
      }

      if (host == GitHost.github) {
        await _runGithubBuild(link.repo, projectDir);
      } else {
        await _runGiteeBuild(link.repo);
      }
    } catch (e) {
      if ('$e' == '已取消') {
        _status = BuildStatus.cancelled;
        _append('==> 已取消（云端运行仍会继续）');
      } else {
        _fail('$e');
      }
    } finally {
      _finishedAt = DateTime.now();
      _currentTask = '';
      if (BuildNotificationService.instance.isRunning) {
        unawaited(BuildNotificationService.instance.stop());
      }
      _safeNotify();
    }
  }

  /// 申请通知权限并启动构建保活前台服务
  Future<void> _startKeepAlive(String text) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.notification.request();
      } catch (_) {
        // 用户拒绝通知权限时前台服务仍会运行
      }
    }
    await BuildNotificationService.instance.start(text);
  }

  String _stepSummary() {
    for (final job in _jobs) {
      for (final step in job.steps) {
        if (step.isRunning) return step.name;
      }
    }
    for (final job in _jobs) {
      if (job.isRunning) return job.name;
    }
    return _currentTask.isEmpty ? '云端构建进行中' : _currentTask;
  }

  /// 刷新 workflow 步骤并同步常驻通知文案
  void _setJobs(List<WorkflowJob> jobs) {
    _jobs = jobs;
    final summary = _stepSummary();
    if (isRunning && summary.isNotEmpty) {
      _currentTask = summary;
      unawaited(BuildNotificationService.instance.update(summary));
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // GitHub Actions
  // ---------------------------------------------------------------------------

  Future<void> _runGithubBuild(String repo, String projectDir) async {
    final api = _github.api!;

    _currentTask = '检查构建 workflow';
    _append('==> 检查 GitHub Actions workflow（${payload.name}）');
    await BuildService.instance.ensureWorkflow(
      api,
      repo,
      path: payload.workflowPath,
      content: payload.workflowContent,
    );
    _append('    workflow 已就绪');

    _currentTask = '触发云端构建';
    _append('==> 触发 workflow_dispatch（build_type=${_type.inputValue}）');
    final triggeredAt = await BuildService.instance.dispatch(
      api,
      repo,
      _type,
      path: payload.workflowPath,
    );
    _append('    已触发，等待运行开始...');

    _currentTask = '云端构建中';
    final run = await BuildService.instance.waitForCompletion(
      api,
      repo,
      triggeredAt,
      isCancelled: () => _cancelRequested,
      onUpdate: (run) {
        _runUrl = run.htmlUrl;
        _runId = run.id;
        _append('==> 运行 #${run.runNumber} 状态：${run.status}');
        // 登录用户把监听注册到服务端（退出 IDE 后继续同步）
        unawaited(_registerServerWatch(repo, run));
        _safeNotify();
      },
      onJobs: _setJobs,
    );
    _runUrl = run.htmlUrl;
    _runId = run.id;
    _append('==> 运行结束：${run.conclusion}');
    _append('    $runUrl');

    if (run.conclusion != 'success') {
      _fail('云端构建未成功（${run.conclusion}），请到 GitHub 查看日志');
      return;
    }

    final settings = _settings?.settings;
    if (settings != null && !settings.buildAutoDownload) {
      _status = BuildStatus.success;
      _append('==> 构建成功（已按偏好设置跳过自动下载产物）');
      return;
    }

    _currentTask = '获取构建产物';
    _append('==> 获取构建产物');
    final relay = settings?.buildServerRelay ?? true;
    if (relay && _account?.isSignedIn == true && _watchId.isNotEmpty) {
      _append('    优先从服务端中转下载（缓解国内访问 GitHub 慢）');
      final path = await _downloadArtifactFromServer(projectDir);
      if (path != null) {
        _artifactPath = path;
        _append('==> 构建产物：$path');
        _status = BuildStatus.success;
        _append('==> 构建成功（耗时 ${_durationText()}）');
        return;
      }
      _append('    服务端产物暂不可用，回退为直接下载');
    }

    final artifacts = await api.listArtifacts(repo, run.id);
    final usable = artifactsForType(artifacts: artifacts, type: _type);
    if (usable == null) {
      _fail('构建成功但未找到可用产物');
      return;
    }
    final path = await BuildService.instance.downloadAndExtractArtifact(
      api,
      repo,
      usable,
      projectDir,
      _type,
    );
    if (path == null) {
      _fail('产物包内未找到 ${_type.artifactExt} 文件');
      return;
    }
    _artifactPath = path;
    _append('==> 构建产物：$path');
    _status = BuildStatus.success;
    _append('==> 构建成功（耗时 ${_durationText()}）');
  }

  /// 把本次运行注册到服务端（仅登录用户）
  Future<void> _registerServerWatch(String repo, WorkflowRun run) async {
    if (_watchId.isNotEmpty) return;
    final account = _account;
    final githubToken = _github.token;
    if (account == null || !account.isSignedIn || githubToken == null) return;
    if (!BuildWatchService.instance.isConfigured) return;
    final watch = await BuildWatchService.instance.register(
      accountToken: account.token!,
      githubToken: githubToken,
      repo: repo,
      runId: run.id,
      runUrl: run.htmlUrl,
      buildType: _type.inputValue,
    );
    if (watch != null && watch.id.isNotEmpty) {
      _watchId = watch.id;
      _append('    已注册服务端构建监听（退出 IDE 后仍会同步）');
    }
  }

  /// 等待服务端把产物下载完成，再取回本地
  Future<String?> _downloadArtifactFromServer(String projectDir) async {
    final account = _account;
    if (account == null || !account.isSignedIn) return null;
    final token = account.token!;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    BuildWatch? watch;
    while (DateTime.now().isBefore(deadline)) {
      if (_cancelRequested) return null;
      watch = await BuildWatchService.instance.fetch(
        accountToken: token,
        id: _watchId,
      );
      if (watch != null && watch.artifactReady) break;
      if (watch != null && watch.error.isNotEmpty) {
        _append('    服务端下载产物失败：${watch.error}');
        return null;
      }
      await Future.delayed(const Duration(seconds: 8));
    }
    if (watch == null || !watch.artifactReady) return null;
    _append('    服务端已就绪（${watch.artifactName}），开始下发到本地');
    final bytes = await BuildWatchService.instance.downloadArtifact(
      accountToken: token,
      id: _watchId,
    );
    if (bytes == null) return null;
    return BuildService.instance.saveArtifactZip(bytes, projectDir, _type);
  }

  // ---------------------------------------------------------------------------
  // 服务端监听恢复（重新进入 IDE 时同步构建进度）
  // ---------------------------------------------------------------------------

  /// 从服务端恢复当前仓库最新一次构建进度
  ///
  /// [projectDir] 用于自动下载已完成的服务端中转产物。
  Future<void> syncFromServer({String? projectDir}) async {
    final account = _account;
    if (account == null || !account.isSignedIn) return;
    final repo = _gitSync.currentLink?.repo;
    if (repo == null || !BuildWatchService.instance.isConfigured) return;
    final watch = await BuildWatchService.instance.latest(
      accountToken: account.token!,
      repo: repo,
    );
    if (watch == null || watch.runId == 0) return;
    // 本地正在轮询同一运行时不覆盖
    if (isRunning && _runId == watch.runId) return;
    if (_runId == watch.runId && _status != BuildStatus.idle) {
      // 本地已有同一运行的最终状态，仅补全步骤
      if (watch.jobs.isNotEmpty) _jobs = watch.jobs;
      _safeNotify();
      return;
    }

    final conclusion = watch.conclusion ?? '';
    _runId = watch.runId;
    _watchId = watch.id;
    _runUrl = watch.htmlUrl;
    _startedAt ??= watch.jobs.isNotEmpty ? watch.jobs.first.startedAt : null;
    _finishedAt = null;
    _logs.clear();
    _append('==> 从服务端恢复构建进度（运行 #${watch.runId}）');
    _jobs = watch.jobs;

    if (!watch.isCompleted) {
      _status = BuildStatus.running;
      _currentTask = '云端构建中（服务端监听）';
      _append('    当前状态：${watch.status}');
      _append('    关闭 IDE 后仍会由服务端持续同步');
      _safeNotify();
      return;
    }

    _finishedAt = DateTime.now();
    switch (conclusion) {
      case 'success':
        _status = BuildStatus.success;
        _append('==> 构建成功');
        final settings = _settings?.settings;
        if (watch.artifactReady &&
            (settings?.buildAutoDownload ?? true) &&
            (settings?.buildServerRelay ?? true) &&
            projectDir != null) {
          _currentTask = '获取构建产物';
          _safeNotify();
          final bytes = await BuildWatchService.instance.downloadArtifact(
            accountToken: account.token!,
            id: watch.id,
          );
          if (bytes != null) {
            _artifactPath = await BuildService.instance.saveArtifactZip(
              bytes,
              projectDir,
              _type,
            );
            if (_artifactPath != null) {
              _append('==> 构建产物：$_artifactPath');
            }
          }
          _currentTask = '';
        }
        break;
      case 'cancelled':
        _status = BuildStatus.cancelled;
        _append('==> 构建已取消');
        break;
      default:
        _status = BuildStatus.failed;
        _error = '云端构建未成功（$conclusion）';
        _append('==> 失败：$_error');
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Gitee Go
  // ---------------------------------------------------------------------------

  Future<void> _runGiteeBuild(String repo) async {
    final api = _gitee.api!;

    // 1. 确保仓库已开通 Gitee Go（未开通时 .workflow 不会被识别、push 不触发构建）
    //    POST /v5/repos/{owner}/{repo}/open，幂等可重复调用
    _currentTask = '确认 Gitee Go 开通状态';
    _append('==> 确认 Gitee Go 已开通');
    try {
      await api.openGiteeGo(repo);
      _append('    Gitee Go 已就绪');
    } catch (e) {
      _append('    ⚠ Gitee Go 开通失败：$e');
      _append('    可到仓库「云原生」页面手动开通后重试');
    }

    // 2. 确保流水线配置存在（首次构建时自动注入 .workflow/slipe_build.yml）
    _currentTask = '检查 Gitee Go 流水线';
    _append('==> 检查 Gitee Go 流水线');
    final exists = await api.fileExists(
      repo,
      GiteeGoTemplates.workflowPath,
      'master',
    );
    if (!exists) {
      _append('    推送 .workflow/slipe_build.yml（仅 Android）');
      await api.pushFiles(
        repo,
        [
          RepoFile(
            GiteeGoTemplates.workflowPath,
            Uint8List.fromList(
              utf8.encode(GiteeGoTemplates.flutterBuildPipeline),
            ),
          ),
        ],
        message: 'ci: add SLIPE Gitee Go pipeline',
        branch: 'master',
      );
    } else {
      _append('    流水线已存在');
    }

    // 3. 推送触发提交。
    //    Gitee 不支持 API 触发构建，只能靠 push 事件；
    //    push 无文件改动时不会触发流水线，
    //    因此每次写入带时间戳的 trigger 文件，保证必定产生新提交。
    _currentTask = '触发 Gitee Go';
    _append('==> 推送触发提交（Gitee Go 由 push 自动触发）');
    await api.pushFiles(
      repo,
      [
        RepoFile(
          '.workflow/.slipe-trigger',
          Uint8List.fromList(
            utf8.encode('triggered at ${DateTime.now().toIso8601String()}\n'),
          ),
        ),
      ],
      message: 'ci: trigger SLIPE build',
      branch: 'master',
    );

    _runUrl = GitHost.gitee.ciUrl(repo);
    _status = BuildStatus.success;
    _append('==> Gitee Go 流水线已触发');
    _append('    $_runUrl');
    _append('    注意：Gitee Go 无 macOS Runner，iOS 构建已禁用；');
    _append('    且 Gitee 未提供运行状态/产物下载 API，请到 Gitee 查看结果。');
  }

  /// 从产物列表中挑选与构建类型匹配的产物
  static RunArtifact? artifactsForType({
    required List<RunArtifact> artifacts,
    required BuildType type,
  }) {
    final usable = artifacts.where((a) => !a.expired).toList();
    if (usable.isEmpty) return null;
    final expected = 'slipe-${type.inputValue}';
    return usable.firstWhere(
      (a) => a.name == expected,
      orElse: () => usable.first,
    );
  }

  void _fail(String message) {
    _error = message;
    _status = BuildStatus.failed;
    _finishedAt = DateTime.now();
    _append('==> 失败：$message');
    _safeNotify();
  }

  String _durationText() {
    final d = duration;
    if (d == null) return '-';
    if (d.inMinutes > 0) {
      return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
    }
    return '${d.inSeconds} 秒';
  }

  /// 取消当前构建（同时请求 GitHub 取消云端工作流）
  Future<void> cancel() async {
    if (!isRunning) return;
    _append('==> 正在请求取消云端工作流...');
    final runId = _runId;
    final repo = _gitSync.currentLink?.repo;
    if (runId != null && repo != null && _github.isSignedIn) {
      try {
        await _github.api!.cancelRun(repo, runId);
        _append('    已向 GitHub 发送取消请求');
      } catch (e) {
        _append('    取消请求失败：$e');
      }
    }
    _cancelRequested = true;
    _safeNotify();
  }

  /// 安装构建产物 APK
  Future<bool> installArtifact() async {
    if (_artifactPath == null) return false;
    if (!_artifactPath!.endsWith('.apk')) {
      _error = '该产物无法直接安装（仅 APK 可安装）';
      _safeNotify();
      return false;
    }
    return BuildService.instance.installApk(_artifactPath!);
  }

  void clearLogs() {
    _logs.clear();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
