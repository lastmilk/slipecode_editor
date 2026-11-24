import '../../services/desktop_platform.dart';

/// 本地任务类型。
enum LocalTaskKind { build, run, test, analyze }

extension LocalTaskKindLabel on LocalTaskKind {
  String get label => switch (this) {
        LocalTaskKind.build => '构建',
        LocalTaskKind.run => '运行',
        LocalTaskKind.test => '测试',
        LocalTaskKind.analyze => '分析',
      };
}

/// 本地构建目标（按载荷与宿主平台过滤）。
class LocalBuildTarget {
  final String id;
  final String label;

  /// 对应 Payload id：flutter / node / taro / android / html / custom
  final String payloadId;

  /// Flutter 构建子命令（apk / appbundle / web / linux / windows / macos / ios）
  final String? flutterTarget;

  /// 支持的宿主平台
  final List<String> hosts;

  final bool requiresFlutter;
  final bool requiresNode;
  final bool requiresAndroidSdk;
  final bool requiresPython;
  final bool requiresJava;
  final bool requiresCompiler;

  const LocalBuildTarget({
    required this.id,
    required this.label,
    required this.payloadId,
    this.flutterTarget,
    this.hosts = const ['linux', 'windows', 'macos'],
    this.requiresFlutter = false,
    this.requiresNode = false,
    this.requiresAndroidSdk = false,
    this.requiresPython = false,
    this.requiresJava = false,
    this.requiresCompiler = false,
  });

  bool get availableOnHost => hosts.contains(DesktopPlatform.hostOs);

  String get unavailableReason => availableOnHost
      ? ''
      : '该目标仅支持 ${hosts.join(' / ')} 宿主';
}

const List<LocalBuildTarget> localBuildTargets = [
  LocalBuildTarget(
    id: 'flutter.apk',
    label: 'Android APK',
    payloadId: 'flutter',
    flutterTarget: 'apk',
    requiresFlutter: true,
    requiresAndroidSdk: true,
  ),
  LocalBuildTarget(
    id: 'flutter.aab',
    label: 'Android AppBundle',
    payloadId: 'flutter',
    flutterTarget: 'appbundle',
    requiresFlutter: true,
    requiresAndroidSdk: true,
  ),
  LocalBuildTarget(
    id: 'flutter.web',
    label: 'Web',
    payloadId: 'flutter',
    flutterTarget: 'web',
    requiresFlutter: true,
  ),
  LocalBuildTarget(
    id: 'flutter.linux',
    label: 'Linux Desktop',
    payloadId: 'flutter',
    flutterTarget: 'linux',
    hosts: ['linux'],
    requiresFlutter: true,
  ),
  LocalBuildTarget(
    id: 'flutter.windows',
    label: 'Windows Desktop',
    payloadId: 'flutter',
    flutterTarget: 'windows',
    hosts: ['windows'],
    requiresFlutter: true,
  ),
  LocalBuildTarget(
    id: 'flutter.macos',
    label: 'macOS Desktop',
    payloadId: 'flutter',
    flutterTarget: 'macos',
    hosts: ['macos'],
    requiresFlutter: true,
  ),
  LocalBuildTarget(
    id: 'flutter.ios',
    label: 'iOS（无签名）',
    payloadId: 'flutter',
    flutterTarget: 'ios',
    hosts: ['macos'],
    requiresFlutter: true,
  ),
  LocalBuildTarget(
    id: 'android.apk',
    label: 'Gradle APK',
    payloadId: 'android',
    requiresAndroidSdk: true,
  ),
  LocalBuildTarget(
    id: 'node.build',
    label: 'Node / Taro',
    payloadId: 'node',
    requiresNode: true,
  ),
  LocalBuildTarget(
    id: 'html.preview',
    label: 'HTML 预览',
    payloadId: 'html',
  ),
  LocalBuildTarget(
    id: 'custom.script',
    label: '自定义脚本（.slipe.json）',
    payloadId: 'custom',
  ),
  LocalBuildTarget(
    id: 'python.project',
    label: 'Python 项目',
    payloadId: 'python',
    requiresPython: true,
  ),
  LocalBuildTarget(
    id: 'java.project',
    label: 'Java（Gradle / Maven）',
    payloadId: 'java',
    requiresJava: true,
  ),
  LocalBuildTarget(
    id: 'cpp.project',
    label: 'C++（Make / CMake）',
    payloadId: 'cpp',
    requiresCompiler: true,
  ),
];

/// 按载荷过滤可用的本地构建目标。
List<LocalBuildTarget> localTargetsFor(String payloadId, {String? projectPath}) {
  final result = <LocalBuildTarget>[];
  for (final target in localBuildTargets) {
    if (payloadId == 'loader') continue;
    if (payloadId == 'taro') {
      if (target.id != 'node.build') continue;
    } else if (payloadId == 'node') {
      if (target.id != 'node.build' && target.id != 'custom.script') continue;
    } else if (target.payloadId != payloadId) {
      continue;
    }
    if (!target.availableOnHost) continue;
    result.add(target);
  }
  // 无法识别载荷时允许自定义脚本
  if (result.isEmpty && payloadId.isEmpty) {
    result.add(localBuildTargets.last);
  }
  return result;
}

enum LocalStepStatus { pending, running, success, failed, skipped }

/// 构建步骤（可变：运行中更新状态与退出码）。
class LocalBuildStep {
  final String name;
  final String executable;
  final List<String> args;

  /// 为 true 时通过系统 shell 执行（自定义脚本）
  final bool shell;

  LocalStepStatus status;
  int? exitCode;
  DateTime? startedAt;
  DateTime? finishedAt;

  LocalBuildStep({
    required this.name,
    required this.executable,
    this.args = const [],
    this.shell = false,
    this.status = LocalStepStatus.pending,
  });

  String get displayCommand =>
      shell ? [executable, ...args].join(' ') : '$executable ${args.join(' ')}'.trim();

  Duration? get duration {
    final start = startedAt;
    final end = finishedAt;
    if (start == null || end == null) return null;
    return end.difference(start);
  }
}

enum LocalTaskStatus { running, success, failed, cancelled }

class LocalArtifact {
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;

  const LocalArtifact({
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  String get name => path.split(RegExp(r'[/\\]')).last;
}

/// 一次本地构建 / 运行任务。
class LocalBuildTask {
  final String id;
  final String projectPath;
  final LocalBuildTarget target;
  final LocalTaskKind kind;
  final DateTime startedAt;

  final List<LocalBuildStep> steps;
  final List<String> logs;
  final List<LocalArtifact> artifacts = [];

  LocalTaskStatus status = LocalTaskStatus.running;
  DateTime? finishedAt;
  String? error;

  LocalBuildTask({
    required this.id,
    required this.projectPath,
    required this.target,
    required this.kind,
    required this.steps,
    DateTime? startedAt,
  })  : startedAt = startedAt ?? DateTime.now(),
        logs = [];

  bool get isRunning => status == LocalTaskStatus.running;

  void log(String line) => logs.add(line);

  Map<String, dynamic> toHistoryJson() => {
        'id': id,
        'projectPath': projectPath,
        'target': target.id,
        'targetLabel': target.label,
        'kind': kind.name,
        'status': status.name,
        'startedAt': startedAt.millisecondsSinceEpoch,
        'finishedAt': finishedAt?.millisecondsSinceEpoch,
      };

  static LocalBuildTask? fromHistoryJson(Map<String, dynamic> json) {
    final targetId = json['target'] as String?;
    final target =
        localBuildTargets.where((item) => item.id == targetId).firstOrNull;
    if (target == null) return null;
    final kind = LocalTaskKind.values
        .where((item) => item.name == json['kind'])
        .firstOrNull;
    if (kind == null) return null;
    final task = LocalBuildTask(
      id: (json['id'] as String?) ?? '',
      projectPath: (json['projectPath'] as String?) ?? '',
      target: target,
      kind: kind,
      steps: const [],
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['startedAt'] as num?)?.toInt() ?? 0,
      ),
    );
    task.status = LocalTaskStatus.values
            .where((item) => item.name == json['status'])
            .firstOrNull ??
        LocalTaskStatus.success;
    final finishedAt = (json['finishedAt'] as num?)?.toInt();
    task.finishedAt = finishedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(finishedAt);
    return task;
  }
}

class LocalBuildException implements Exception {
  final String message;

  const LocalBuildException(this.message);

  @override
  String toString() => message;
}
