import 'dart:io';

/// 工具链种类。
enum ToolchainKind { flutter, dart, node, java, python }

/// 工具链种类相关的平台信息。
extension ToolchainKindInfo on ToolchainKind {
  String get id => name;

  String get label => switch (this) {
        ToolchainKind.flutter => 'Flutter',
        ToolchainKind.dart => 'Dart',
        ToolchainKind.node => 'Node.js',
        ToolchainKind.java => 'JDK',
        ToolchainKind.python => 'Python',
      };

  /// 冒烟测试参数
  List<String> get versionArgs => switch (this) {
        ToolchainKind.flutter => const ['--version'],
        ToolchainKind.dart => const ['--version'],
        ToolchainKind.node => const ['-v'],
        ToolchainKind.java => const ['-version'],
        ToolchainKind.python => const ['--version'],
      };

  /// 可执行文件相对于安装目录的路径
  String get executableRelative => switch (this) {
        ToolchainKind.flutter =>
          Platform.isWindows ? 'bin/flutter.bat' : 'bin/flutter',
        ToolchainKind.dart =>
          Platform.isWindows ? 'bin/dart.exe' : 'bin/dart',
        ToolchainKind.node => Platform.isWindows ? 'node.exe' : 'bin/node',
        ToolchainKind.java =>
          Platform.isWindows ? 'bin/java.exe' : 'bin/java',
        ToolchainKind.python =>
          Platform.isWindows ? 'python.exe' : 'bin/python3',
      };

  /// 环境变量里需要指向的目录（安装目录下的 bin）
  String get binRelative => switch (this) {
        ToolchainKind.node => Platform.isWindows ? '' : 'bin',
        _ => 'bin',
      };

  static ToolchainKind? fromId(String id) {
    for (final kind in ToolchainKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// 宿主架构：x64 / arm64。
String get hostArchitecture {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final value = (env['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();
    return value.contains('arm') ? 'arm64' : 'x64';
  }
  try {
    final result = Process.runSync('uname', const ['-m']);
    final value = '${result.stdout}'.trim().toLowerCase();
    if (value.contains('aarch64') || value.contains('arm64')) return 'arm64';
  } catch (_) {
    // 忽略：按 x64 处理
  }
  return 'x64';
}

/// 一个可安装的版本。
class ToolchainRelease {
  final ToolchainKind kind;
  final String version;
  final String url;

  /// 归档大小（字节），清单未提供时为 null
  final int? sizeBytes;

  /// SHA-256 校验值，清单未提供时为 null
  final String? sha256;

  /// 是否 LTS（Node / JDK）
  final bool lts;

  const ToolchainRelease({
    required this.kind,
    required this.version,
    required this.url,
    this.sizeBytes,
    this.sha256,
    this.lts = false,
  });

  String get fileName {
    final path = Uri.tryParse(url)?.path ?? url;
    final name = path.split('/').last;
    // 部分下载地址（如 Adoptium 的 /eclipse）不带扩展名，这里补一个
    if (name.isEmpty || !name.contains('.')) {
      final extension = Platform.isWindows
          ? 'zip'
          : kind == ToolchainKind.java
              ? 'tar.gz'
              : '';
      return '${kind.id}-$version${extension.isEmpty ? '' : '.$extension'}';
    }
    return name;
  }

  @override
  String toString() => '${kind.id}@$version';
}

/// 已安装的工具链。
class InstalledToolchain {
  final ToolchainKind kind;
  final String version;
  final String path;

  /// 安装完成时间（毫秒时间戳）
  final int installedAt;

  /// 冒烟测试输出（`flutter --version` 等），可能为空
  final String smoke;

  const InstalledToolchain({
    required this.kind,
    required this.version,
    required this.path,
    required this.installedAt,
    this.smoke = '',
  });

  String get executablePath =>
      '$path${Platform.pathSeparator}${kind.executableRelative}';

  bool get isIntact => File(executablePath).existsSync();

  Map<String, dynamic> toJson() => {
        'kind': kind.id,
        'version': version,
        'path': path,
        'installedAt': installedAt,
        'smoke': smoke,
      };

  static InstalledToolchain? fromJson(Map<String, dynamic> json) {
    final kind = ToolchainKindInfo.fromId((json['kind'] as String?) ?? '');
    final version = json['version'] as String?;
    final path = json['path'] as String?;
    if (kind == null || version == null || path == null) return null;
    return InstalledToolchain(
      kind: kind,
      version: version,
      path: path,
      installedAt: (json['installedAt'] as num?)?.toInt() ?? 0,
      smoke: (json['smoke'] as String?) ?? '',
    );
  }
}

/// 安装阶段。
enum ToolchainPhase {
  queued,
  downloading,
  verifying,
  extracting,
  installing,
  done,
  failed,
  cancelled,
}

extension ToolchainPhaseLabel on ToolchainPhase {
  bool get isRunning => switch (this) {
        ToolchainPhase.queued ||
        ToolchainPhase.downloading ||
        ToolchainPhase.verifying ||
        ToolchainPhase.extracting ||
        ToolchainPhase.installing =>
          true,
        _ => false,
      };
}

/// 安装进度事件。
class ToolchainProgress {
  final ToolchainKind kind;
  final String version;
  final ToolchainPhase phase;
  final int received;
  final int total;
  final String message;

  const ToolchainProgress({
    required this.kind,
    required this.version,
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.message = '',
  });

  /// 下载进度 0~1；总大小未知时为 null
  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  ToolchainProgress copyWith({
    ToolchainPhase? phase,
    int? received,
    int? total,
    String? message,
  }) =>
      ToolchainProgress(
        kind: kind,
        version: version,
        phase: phase ?? this.phase,
        received: received ?? this.received,
        total: total ?? this.total,
        message: message ?? this.message,
      );
}

/// 下载 / 安装任务取消令牌（不实现断点续传，取消后清理临时目录）。
class ToolchainCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const ToolchainCancelledException();
  }
}

class ToolchainCancelledException implements Exception {
  const ToolchainCancelledException();

  @override
  String toString() => '安装已取消';
}

/// 人类可读体积。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// 版本号比较（按数字段，忽略前缀 v）。
int compareVersions(String a, String b) {
  List<int> parse(String value) => value
      .replaceAll(RegExp(r'^v'), '')
      .split(RegExp(r'[.+-]'))
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final left = parse(a);
  final right = parse(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}
