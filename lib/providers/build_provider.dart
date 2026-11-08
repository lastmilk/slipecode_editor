import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../payloads/project_payload.dart';
import '../services/build_service.dart';
import '../services/build_watch_service.dart';
import '../services/git_host.dart';
import '../services/gitee_go_templates.dart';
import '../services/github_api_service.dart'
    show RepoFile, RunArtifact, WorkflowJob, WorkflowRun;
import '../services/live_task_service.dart';
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

  /// 是否处于构建初始化阶段（同步代码 / 触发 workflow）
  bool _initializing = false;

  BuildStatus get status => _status;

  /// 初始化中：界面用遮罩弹窗提示，初始化完成后展示实际构建进程
  bool get isInitializing => _initializing;

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
    unawaited(LiveTaskService.instance.stop('build'));
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
      _fail(t('build.error.policyFirst'));
      return;
    }

    final link = _gitSync.currentLink;
    if (link == null) {
      _status = BuildStatus.failed;
      _error = t('build.error.noRepo');
      _append(t('build.log.failed', {'error': _error}));
      _safeNotify();
      return;
    }
    final host = link.host;
    final types = availableTypes;
    if (types.isEmpty) {
      _fail(t('build.error.noTypes', {
        'payload': payload.name,
        'ci': host.ciName,
      }));
      return;
    }
    if (!types.contains(_type)) {
      _type = types.first;
    }
    if (host == GitHost.gitee && !payload.supportsGitee) {
      _fail(t('build.error.payloadNotGitee', {'payload': payload.name}));
      return;
    }
    if (host == GitHost.gitee && !_gitee.isSignedIn) {
      _fail(t('build.error.notSignedInGitee'));
      return;
    }
    if (host == GitHost.github && !_github.isSignedIn) {
      _fail(t('build.error.notSignedInGithub'));
      return;
    }
    if (host == GitHost.gitee && _type.isIos) {
      _fail(t('build.error.noMacRunner'));
      return;
    }

    _status = BuildStatus.running;
    _initializing = true;
    _currentTask = t('build.task.cloudBuild', {'type': _type.label});
    _reset();
    _append(t('build.log.start', {'type': _type.label, 'ci': host.ciName}));

    // 构建期间启动前台服务 + 常驻通知，避免退到后台后进程被回收
    await _startKeepAlive(t('build.task.preparing'));

    try {
      // 1. 构建前全量比对本地与远程，自动补推所有差异文件
      _currentTask = t('build.task.syncing');
      _append(t('build.log.syncTo', {'repo': link.repo}));
      final ok = await _gitSync.ensureUpToDate(projectDir: projectDir);
      if (!ok) {
        throw StateError(
          t('build.syncFailed', {
            'error': _gitSync.error ?? t('build.unknown'),
          }),
        );
      }
      _append(t('build.log.noPending'));

      if (host == GitHost.github) {
        await _runGithubBuild(link.repo, projectDir);
      } else {
        await _runGiteeBuild(link.repo);
      }
    } catch (e) {
      if ('$e' == '已取消') {
        _status = BuildStatus.cancelled;
        _append(t('build.log.cancelled'));
      } else {
        _fail('$e');
      }
    } finally {
      _initializing = false;
      _finishedAt = DateTime.now();
      _currentTask = '';
      if (_status == BuildStatus.success) {
        unawaited(
          LiveTaskService.instance.finish(
            id: 'build',
            kind: 'build',
            title: '云端构建完成',
            text: '构建成功',
          ),
        );
      } else {
        unawaited(LiveTaskService.instance.stop('build'));
      }
      _safeNotify();
    }
  }

  /// 申请通知权限并启动构建实况通知
  Future<void> _startKeepAlive(String text) async {
    final enabled = _settings?.settings.liveNotifications ?? true;
    LiveTaskService.instance.configure(enabled: enabled);
    if (!enabled) return;
    await LiveTaskService.ensurePermission();
    await LiveTaskService.instance.start(
      id: 'build',
      kind: 'build',
      title: 'SLIPE 云端构建',
      text: text,
      progress: null,
      indeterminate: true,
    );
  }

  /// 按 workflow 步骤完成度估算构建进度（0-99）
  int? _buildProgress() {
    var total = 0;
    var done = 0;
    for (final job in _jobs) {
      for (final step in job.steps) {
        total++;
        if (step.isCompleted) done++;
      }
    }
    if (total == 0) return null;
    return (done * 100 / total).round().clamp(0, 99);
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
    return _currentTask.isEmpty ? t('build.task.inProgress') : _currentTask;
  }

  /// 刷新 workflow 步骤并同步实况通知文案与进度
  void _setJobs(List<WorkflowJob> jobs) {
    _jobs = jobs;
    final summary = _stepSummary();
    if (isRunning && summary.isNotEmpty) {
      _currentTask = summary;
      unawaited(
        LiveTaskService.instance.update(
          id: 'build',
          kind: 'build',
          title: 'SLIPE 云端构建',
          text: summary,
          progress: _buildProgress(),
          indeterminate: _buildProgress() == null,
        ),
      );
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // GitHub Actions
  // ---------------------------------------------------------------------------

  Future<void> _runGithubBuild(String repo, String projectDir) async {
    final api = _github.api!;

    _currentTask = t('build.task.checkWorkflow');
    _append(t('build.log.checkWorkflow', {'payload': payload.name}));
    await BuildService.instance.ensureWorkflow(
      api,
      repo,
      path: payload.workflowPath,
      content: payload.workflowContent,
    );
    _append(t('build.log.workflowReady'));

    _currentTask = t('build.task.trigger');
    _append(t('build.log.dispatch', {'type': _type.inputValue}));
    final triggeredAt = await BuildService.instance.dispatch(
      api,
      repo,
      _type,
      path: payload.workflowPath,
    );
    _append(t('build.log.dispatched'));

    _currentTask = t('build.task.building');
    // 等待 GitHub 创建 run 记录（初始化阶段）
    final run = await BuildService.instance.waitForRunStarted(
      api,
      repo,
      triggeredAt,
      isCancelled: () => _cancelRequested,
    );
    _runUrl = run.htmlUrl;
    _runId = run.id;
    _append(
      t('build.log.runStatus', {
        'number': '${run.runNumber}',
        'status': run.status,
      }),
    );
    // 初始化完成：关闭遮罩弹窗，开始展示实际构建进程
    _initializing = false;
    _safeNotify();

    // 注册服务端监听：软件运行期间改为轮询服务端进度，实现跨端一致的实时同步
    await _registerServerWatch(repo, run);
    WorkflowRun finalRun = run;
    BuildWatch? watch;
    if (_watchId.isNotEmpty) {
      _append('已切换服务端进度同步（每 4 秒轮询）');
      watch = await _pollServerWatch(run);
      if (watch != null) {
        finalRun = WorkflowRun(
          id: run.id,
          name: run.name,
          status: watch.status,
          conclusion: watch.conclusion,
          htmlUrl: watch.htmlUrl.isEmpty ? run.htmlUrl : watch.htmlUrl,
          createdAt: run.createdAt,
          runNumber: run.runNumber,
          headBranch: run.headBranch,
        );
        if (watch.jobs.isNotEmpty) _setJobs(watch.jobs);
        _runUrl = finalRun.htmlUrl;
      }
    }
    if (watch == null) {
      // 未登录 / 服务端不可用：回退为直连 GitHub 轮询
      _append('服务端进度不可用，回退为直连 GitHub 轮询');
      finalRun = await BuildService.instance.waitForCompletion(
        api,
        repo,
        triggeredAt,
        isCancelled: () => _cancelRequested,
        onUpdate: (current) {
          _runUrl = current.htmlUrl;
          _runId = current.id;
          _append(
            t('build.log.runStatus', {
              'number': '${current.runNumber}',
              'status': current.status,
            }),
          );
          unawaited(_registerServerWatch(repo, current));
          _safeNotify();
        },
        onJobs: _setJobs,
      );
    }

    _runUrl = finalRun.htmlUrl;
    _runId = finalRun.id;
    _append(t('build.log.runFinished',
        {'conclusion': finalRun.conclusion ?? 'unknown'}));
    _append('    $runUrl');

    if (finalRun.conclusion != 'success') {
      if (finalRun.conclusion == 'cancelled' || _cancelRequested) {
        _status = BuildStatus.cancelled;
        _append(t('build.log.buildCancelled'));
        return;
      }
      _fail(
        t('build.error.notSuccessfulGithub', {
          'conclusion': finalRun.conclusion ?? 'unknown',
        }),
      );
      return;
    }

    final settings = _settings?.settings;
    if (settings != null && !settings.buildAutoDownload) {
      _status = BuildStatus.success;
      _append(t('build.log.successNoDownload'));
      return;
    }

    _currentTask = t('build.task.artifact');
    _append(t('build.log.getArtifact'));
    final relay = settings?.buildServerRelay ?? true;
    if (relay && _account?.isSignedIn == true && _watchId.isNotEmpty) {
      _append(t('build.log.relayFirst'));
      final path = await _downloadArtifactFromServer(projectDir);
      if (path != null) {
        _artifactPath = path;
        _append(t('build.log.artifact', {'path': path}));
        _status = BuildStatus.success;
        _append(t('build.log.successDuration', {'duration': _durationText()}));
        return;
      }
      _append(t('build.log.relayFallback'));
    }

    final artifacts = await api.listArtifacts(repo, finalRun.id);
    final usable = artifactsForType(artifacts: artifacts, type: _type);
    if (usable == null) {
      _fail(t('build.error.noArtifact'));
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
      _fail(t('build.error.artifactFileMissing', {'ext': _type.artifactExt}));
      return;
    }
    _artifactPath = path;
    _append(t('build.log.artifact', {'path': path}));
    _status = BuildStatus.success;
    _append(t('build.log.successDuration', {'duration': _durationText()}));
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
      _append(t('build.log.watchRegistered'));
    }
  }

  /// 软件运行期间轮询服务端构建进度（实时同步 Job / Step / 状态）
  ///
  /// 连续 6 次查询失败（约 24 秒）时返回 null，由调用方回退为直连 GitHub。
  Future<BuildWatch?> _pollServerWatch(WorkflowRun run) async {
    final account = _account;
    if (account == null || !account.isSignedIn) return null;
    final accountToken = account.token!;
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    var failures = 0;
    var lastStatus = '';
    var lastJobsSignature = '';

    while (DateTime.now().isBefore(deadline)) {
      if (_cancelRequested) return null;
      final watch = await BuildWatchService.instance.fetch(
        accountToken: accountToken,
        id: _watchId,
      );
      if (watch == null) {
        failures += 1;
        if (failures >= 6) return null;
        await Future.delayed(const Duration(seconds: 4));
        continue;
      }
      failures = 0;
      if (watch.status != lastStatus) {
        lastStatus = watch.status;
        _append(
          t('build.log.runStatus', {
            'number': '${run.runNumber}',
            'status': watch.status,
          }),
        );
      }
      if (watch.jobs.isNotEmpty) {
        final signature = watch.jobs
            .map(
              (job) => '${job.name}:${job.status}:'
                  '${job.steps.map((s) => '${s.name}-${s.status}').join(',')}',
            )
            .join('|');
        if (signature != lastJobsSignature) {
          lastJobsSignature = signature;
          _setJobs(watch.jobs);
        }
      }
      if (watch.error.isNotEmpty) {
        _append(t('build.log.relayDownloadFailed', {'error': watch.error}));
        return watch;
      }
      if (watch.isCompleted) return watch;
      await Future.delayed(const Duration(seconds: 4));
    }
    return null;
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
        _append(t('build.log.relayDownloadFailed', {'error': watch.error}));
        return null;
      }
      await Future.delayed(const Duration(seconds: 8));
    }
    if (watch == null || !watch.artifactReady) return null;
    _append(t('build.log.relayReady', {'name': watch.artifactName}));
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
    _append(t('build.log.restoreFromServer', {'id': '${watch.runId}'}));
    _jobs = watch.jobs;

    if (!watch.isCompleted) {
      _status = BuildStatus.running;
      _currentTask = t('build.task.buildingWatched');
      _append(t('build.log.currentStatus', {'status': watch.status}));
      _append(t('build.log.serverWatchHint'));
      _safeNotify();
      return;
    }

    _finishedAt = DateTime.now();
    switch (conclusion) {
      case 'success':
        _status = BuildStatus.success;
        _append(t('build.log.success'));
        final settings = _settings?.settings;
        if (watch.artifactReady &&
            (settings?.buildAutoDownload ?? true) &&
            (settings?.buildServerRelay ?? true) &&
            projectDir != null) {
          _currentTask = t('build.task.artifact');
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
              _append(
                t('build.log.artifact', {'path': _artifactPath!}),
              );
            }
          }
          _currentTask = '';
        }
        break;
      case 'cancelled':
        _status = BuildStatus.cancelled;
        _append(t('build.log.buildCancelled'));
        break;
      default:
        _status = BuildStatus.failed;
        _error = t('build.error.notSuccessful', {'conclusion': conclusion});
        _append(t('build.log.failed', {'error': _error}));
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
    _currentTask = t('build.task.confirmGiteeGo');
    _append(t('build.log.confirmGiteeGo'));
    try {
      await api.openGiteeGo(repo);
      _append(t('build.log.giteeGoReady'));
    } catch (e) {
      _append(t('build.log.giteeGoOpenFailed', {'error': '$e'}));
      _append(t('build.log.giteeGoManualHint'));
    }

    // 2. 确保流水线配置存在（首次构建时自动注入 .workflow/slipe_build.yml）
    _currentTask = t('build.task.checkPipeline');
    _append(t('build.log.checkPipeline'));
    final exists = await api.fileExists(
      repo,
      GiteeGoTemplates.workflowPath,
      'master',
    );
    if (!exists) {
      _append(t('build.log.pushWorkflow'));
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
      _append(t('build.log.pipelineExists'));
    }

    // 3. 推送触发提交。
    //    Gitee 不支持 API 触发构建，只能靠 push 事件；
    //    push 无文件改动时不会触发流水线，
    //    因此每次写入带时间戳的 trigger 文件，保证必定产生新提交。
    _currentTask = t('build.task.triggerGitee');
    _append(t('build.log.pushTrigger'));
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
    _initializing = false;
    _status = BuildStatus.success;
    _append(t('build.log.pipelineTriggered'));
    _append('    $_runUrl');
    _append(t('build.log.giteeGoIosNote'));
    _append(t('build.log.giteeGoApiNote'));
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
    _append(t('build.log.failed', {'error': message}));
    _safeNotify();
  }

  String _durationText() {
    final d = duration;
    if (d == null) return '-';
    if (d.inMinutes > 0) {
      return t('build.durationMinutes', {
        'minutes': '${d.inMinutes}',
        'seconds': '${d.inSeconds % 60}',
      });
    }
    return t('build.durationSeconds', {'seconds': '${d.inSeconds}'});
  }

  /// 取消当前构建（同时请求 GitHub 取消云端工作流）
  Future<void> cancel() async {
    if (!isRunning) return;
    _append(t('build.log.cancelling'));
    final runId = _runId;
    final repo = _gitSync.currentLink?.repo;
    if (runId != null && repo != null && _github.isSignedIn) {
      try {
        await _github.api!.cancelRun(repo, runId);
        _append(t('build.log.cancelSent'));
      } catch (e) {
        _append(t('build.log.cancelFailed', {'error': '$e'}));
      }
    }
    _cancelRequested = true;
    _safeNotify();
  }

  /// 安装构建产物 APK
  Future<bool> installArtifact() async {
    if (_artifactPath == null) return false;
    if (!_artifactPath!.endsWith('.apk')) {
      _error = t('build.error.notInstallable');
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
