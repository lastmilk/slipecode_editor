import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// proot 容器环境配置
class ContainerConfig {
  final String? prootPath;
  final String? rootfsUrl;
  final String? prootUrl;

  const ContainerConfig({this.prootPath, this.rootfsUrl, this.prootUrl});

  Map<String, dynamic> toJson() => {
        'prootPath': prootPath,
        'rootfsUrl': rootfsUrl,
        'prootUrl': prootUrl,
      };

  factory ContainerConfig.fromJson(Map<String, dynamic> json) => ContainerConfig(
        prootPath: json['prootPath'] as String?,
        rootfsUrl: json['rootfsUrl'] as String?,
        prootUrl: json['prootUrl'] as String?,
      );

  ContainerConfig copyWith({String? prootPath, String? rootfsUrl, String? prootUrl}) {
    return ContainerConfig(
      prootPath: prootPath ?? this.prootPath,
      rootfsUrl: rootfsUrl ?? this.rootfsUrl,
      prootUrl: prootUrl ?? this.prootUrl,
    );
  }
}

/// proot 容器服务
///
/// 负责：
/// - 管理 proot 二进制（native lib / 应用私有目录 / 自定义路径）
/// - 下载并解压 rootfs（Alpine minirootfs 等 tar.gz）
/// - 构造标准 proot 执行参数并启动进程
class ContainerService {
  ContainerService._();

  static final ContainerService instance = ContainerService._();

  static const MethodChannel _channel = MethodChannel('slipe/container');

  /// 默认 Alpine rootfs 下载地址（aarch64）
  static const String defaultRootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/'
      'alpine-minirootfs-3.20.3-aarch64.tar.gz';

  /// 容器内默认 PATH（包含可选的 Flutter / Android SDK 安装位置）
  static const String containerPath =
      '/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:'
      '/opt/android-sdk/platform-tools:'
      '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

  Directory? _envRoot;
  String? _nativeLibraryDir;
  ContainerConfig _config = const ContainerConfig();

  bool _initialized = false;

  /// 初始化环境目录并读取配置
  Future<void> init() async {
    if (_initialized) return;

    final support = await getApplicationSupportDirectory();
    _envRoot = Directory(p.join(support.path, 'proot'));
    await _envRoot!.create(recursive: true);
    await Directory(prootDir).create(recursive: true);

    try {
      _nativeLibraryDir = await _channel.invokeMethod<String>('getNativeLibraryDir');
    } catch (_) {
      _nativeLibraryDir = null;
    }

    await _loadConfig();
    _initialized = true;
  }

  String get envRootPath => _envRoot!.path;
  String get rootfsPath => p.join(envRootPath, 'rootfs');
  String get prootDir => p.join(envRootPath, 'bin');
  String get tmpDir => p.join(envRootPath, 'tmp');
  String get cacheDir => p.join(envRootPath, 'cache');
  String get configPath => p.join(envRootPath, 'config.json');

  /// proot 下载后默认落盘位置
  String get managedProotPath => p.join(prootDir, 'proot');

  ContainerConfig get config => _config;

  String? get nativeLibraryDir => _nativeLibraryDir;

  /// 设备架构（aarch64 / armv7l / x86_64 等）
  Future<String> getDeviceArch() async {
    try {
      final arch = await _channel.invokeMethod<String>('getDeviceArch');
      if (arch != null && arch.isNotEmpty) return arch;
    } catch (_) {}
    try {
      final result = await Process.run('/system/bin/uname', ['-m']);
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) return out;
    } catch (_) {}
    return 'aarch64';
  }

  /// 查找可用的 proot 二进制
  ///
  /// 优先级：
  /// 1. 配置中的自定义路径
  /// 2. nativeLibraryDir/libproot.so（jniLibs 方式，推荐，具备执行权限）
  /// 3. 应用私有目录 bin/proot
  /// 4. /data/local/tmp/proot
  Future<String?> resolveProotPath() async {
    await init();

    final candidates = <String?>[
      _config.prootPath,
      if (_nativeLibraryDir != null) p.join(_nativeLibraryDir!, 'libproot.so'),
      managedProotPath,
      '/data/local/tmp/proot',
    ];

    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) continue;
      if (await _isExecutable(candidate)) return candidate;
    }
    return null;
  }

  Future<bool> _isExecutable(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final stat = await file.stat();
      // 检查 owner / group / other 任一执行位
      return (stat.mode & 0x49) != 0;
    } catch (_) {
      return false;
    }
  }

  /// rootfs 是否已安装
  Future<bool> isRootfsInstalled() async {
    final etc = Directory(p.join(rootfsPath, 'etc'));
    final sh = File(p.join(rootfsPath, 'bin', 'sh'));
    final busybox = File(p.join(rootfsPath, 'bin', 'busybox'));
    if (!await etc.exists()) return false;
    return await sh.exists() || await busybox.exists();
  }

  /// 容器是否可用
  Future<bool> isReady() async {
    final proot = await resolveProotPath();
    return proot != null && await isRootfsInstalled();
  }

  // ---------------------------------------------------------------------------
  // 配置读写
  // ---------------------------------------------------------------------------

  Future<void> _loadConfig() async {
    final file = File(configPath);
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _config = ContainerConfig.fromJson(json);
    } catch (_) {
      _config = const ContainerConfig();
    }
  }

  Future<void> saveConfig(ContainerConfig config) async {
    _config = config;
    await File(configPath).writeAsString(jsonEncode(config.toJson()));
  }

  // ---------------------------------------------------------------------------
  // 安装 proot 二进制
  // ---------------------------------------------------------------------------

  /// 从 URL 下载 proot 二进制
  Future<void> installProotFromUrl(
    String url, {
    void Function(String message)? onLog,
    void Function(double progress)? onProgress,
  }) async {
    await init();
    if (!url.startsWith('http')) {
      throw Exception('无效的下载地址：$url');
    }
    if (url.endsWith('.deb')) {
      throw Exception('请提供静态编译的 proot 可执行文件，而不是 .deb 包');
    }

    await Directory(prootDir).create(recursive: true);
    onLog?.call('正在下载 proot: $url');
    await _download(url, managedProotPath, onProgress: onProgress, onLog: onLog);

    await makeExecutable(managedProotPath);
    await saveConfig(_config.copyWith(prootPath: managedProotPath, prootUrl: url));
    onLog?.call('proot 安装完成: $managedProotPath');
  }

  /// 从本地文件导入 proot 二进制
  Future<void> installProotFromFile(
    String sourcePath, {
    void Function(String message)? onLog,
  }) async {
    await init();
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('文件不存在：$sourcePath');
    }
    await Directory(prootDir).create(recursive: true);
    await source.copy(managedProotPath);
    await makeExecutable(managedProotPath);

    // 校验能否执行（未通过则提示使用 jniLibs 方式）
    final probe = await _probeBinary(managedProotPath);
    if (!probe) {
      onLog?.call('警告：proot 无法执行。Android 10+ 可能禁止从应用私有目录执行二进制，'
          '建议将 proot 放到 jniLibs/arm64-v8a/libproot.so 后重新安装应用。');
    } else {
      onLog?.call('proot 可执行性校验通过');
    }

    await saveConfig(_config.copyWith(prootPath: managedProotPath));
  }

  Future<bool> _probeBinary(String path) async {
    try {
      final result = await Process.run(path, ['--version']);
      return result.exitCode == 0 || (result.stderr as String).contains('proot');
    } catch (_) {
      return false;
    }
  }

  /// 赋予可执行权限（优先原生通道，其次系统 chmod）
  Future<void> makeExecutable(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('makeExecutable', {'path': path});
      if (ok == true) return;
    } catch (_) {}

    if (await File('/system/bin/chmod').exists()) {
      final result = await Process.run('/system/bin/chmod', ['755', path]);
      if (result.exitCode != 0) {
        throw Exception('chmod 失败：${result.stderr}');
      }
      return;
    }
    throw Exception('无法设置可执行权限：$path');
  }

  // ---------------------------------------------------------------------------
  // 安装 rootfs
  // ---------------------------------------------------------------------------

  /// 从 URL 下载并解压 rootfs
  Future<void> installRootfsFromUrl(
    String url, {
    void Function(String message)? onLog,
    void Function(double progress)? onProgress,
  }) async {
    await init();
    if (!url.startsWith('http')) {
      throw Exception('无效的下载地址：$url');
    }

    await Directory(cacheDir).create(recursive: true);
    final archivePath = p.join(cacheDir, 'rootfs.tar.gz');

    onLog?.call('正在下载 rootfs: $url');
    await _download(url, archivePath, onProgress: onProgress, onLog: onLog);

    onLog?.call('正在解压 rootfs...');
    await extractRootfs(archivePath, onLog: onLog);

    if (await File(archivePath).exists()) {
      await File(archivePath).delete();
    }

    await saveConfig(_config.copyWith(rootfsUrl: url));
    onLog?.call('rootfs 安装完成: $rootfsPath');
  }

  /// 从本地 tar.gz 导入 rootfs
  Future<void> installRootfsFromFile(
    String archivePath, {
    void Function(String message)? onLog,
  }) async {
    await init();
    if (!await File(archivePath).exists()) {
      throw Exception('文件不存在：$archivePath');
    }
    onLog?.call('正在解压 rootfs: $archivePath');
    await extractRootfs(archivePath, onLog: onLog);
    onLog?.call('rootfs 安装完成: $rootfsPath');
  }

  /// 使用系统 tar 解压 rootfs（可正确处理符号链接）
  Future<void> extractRootfs(
    String archivePath, {
    void Function(String message)? onLog,
  }) async {
    await init();

    if (await Directory(rootfsPath).exists()) {
      await Directory(rootfsPath).delete(recursive: true);
    }
    await Directory(rootfsPath).create(recursive: true);

    final systemTar = File('/system/bin/tar');
    if (await systemTar.exists()) {
      final result = await Process.run(
        '/system/bin/tar',
        ['-xzf', archivePath, '-C', rootfsPath],
      );
      final stderr = (result.stderr as String).trim();
      if (result.exitCode == 0) {
        onLog?.call('解压完成（系统 tar）');
      } else {
        throw Exception('解压失败（exit ${result.exitCode}）: $stderr');
      }
    } else {
      throw Exception('当前设备缺少 /system/bin/tar，无法解压 rootfs');
    }

    await _prepareRootfs(onLog);
  }

  /// 解压后补齐目录、DNS、hosts 等基础配置
  Future<void> _prepareRootfs(void Function(String message)? onLog) async {
    for (final dir in ['dev', 'proc', 'sys', 'tmp', 'root', 'workspace', 'etc']) {
      final d = Directory(p.join(rootfsPath, dir));
      if (!await d.exists()) await d.create(recursive: true);
    }

    await File(p.join(rootfsPath, 'etc', 'resolv.conf')).writeAsString(
      'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
    );
    await File(p.join(rootfsPath, 'etc', 'hosts')).writeAsString(
      '127.0.0.1 localhost\n',
    );

    final shell = File(p.join(rootfsPath, 'bin', 'sh'));
    if (!await shell.exists()) {
      onLog?.call('警告：rootfs 中未找到 /bin/sh，请确认是否为 Alpine/Debian 等标准镜像');
    }
  }

  // ---------------------------------------------------------------------------
  // 执行
  // ---------------------------------------------------------------------------

  /// 构造标准 proot 参数
  List<String> _buildProotArgs({
    required String? projectDir,
    required String workDir,
    required List<String> shellArgs,
  }) {
    final args = <String>[
      '-0',
      '-r',
      rootfsPath,
      '--link2symlink',
      '--kill-on-exit',
      '-b',
      '/dev',
      '-b',
      '/proc',
      '-b',
      '/sys',
      '-w',
      workDir,
    ];

    if (projectDir != null && projectDir.isNotEmpty) {
      args.addAll(['-b', '$projectDir:/workspace']);
    }
    // 允许访问外部存储根目录（导入项目/下载产物）
    args.addAll(['-b', '/storage/emulated/0:/sdcard']);

    args.addAll(shellArgs);
    return args;
  }

  Map<String, String> _processEnvironment() {
    return {
      'HOME': '/root',
      'PATH': containerPath,
      'TERM': 'xterm-256color',
      'LANG': 'C.UTF-8',
      'PROOT_TMP_DIR': tmpDir,
      'PROOT_NO_SECCOMP': '1',
      'ANDROID_HOME': '/opt/android-sdk',
      'ANDROID_SDK_ROOT': '/opt/android-sdk',
    };
  }

  /// 启动一次性命令（返回 Process，由调用方监听输出）
  Future<Process> startCommand(
    String command, {
    String? projectDir,
    String workDir = '/workspace',
  }) async {
    await init();
    final proot = await resolveProotPath();
    if (proot == null) {
      throw Exception('未找到可执行的 proot，请先在容器设置中安装 proot');
    }
    if (!await isRootfsInstalled()) {
      throw Exception('rootfs 未安装，请先在容器设置中安装 rootfs');
    }
    await Directory(tmpDir).create(recursive: true);

    return Process.start(
      proot,
      _buildProotArgs(
        projectDir: projectDir,
        workDir: projectDir == null ? '/root' : workDir,
        shellArgs: ['/bin/sh', '-lc', command],
      ),
      environment: _processEnvironment(),
    );
  }

  /// 启动交互式 shell（供持久终端会话使用）
  Future<Process> startShell({String? projectDir}) async {
    await init();
    final proot = await resolveProotPath();
    if (proot == null) {
      throw Exception('未找到可执行的 proot，请先在容器设置中安装 proot');
    }
    if (!await isRootfsInstalled()) {
      throw Exception('rootfs 未安装，请先在容器设置中安装 rootfs');
    }
    await Directory(tmpDir).create(recursive: true);

    return Process.start(
      proot,
      _buildProotArgs(
        projectDir: projectDir,
        workDir: projectDir == null ? '/root' : '/workspace',
        shellArgs: ['/bin/sh'],
      ),
      environment: _processEnvironment(),
    );
  }

  // ---------------------------------------------------------------------------
  // 下载
  // ---------------------------------------------------------------------------

  Future<void> _download(
    String url,
    String targetPath, {
    void Function(double progress)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.add('User-Agent', 'SLIPE/1.0');
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        throw Exception('下载失败：HTTP ${response.statusCode}');
      }

      final total = response.contentLength;
      var received = 0;

      final sink = File(targetPath).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(received / total);
        }
      }
      await sink.flush();
      await sink.close();

      onLog?.call('下载完成：${(received / 1024 / 1024).toStringAsFixed(1)} MB');
    } catch (e) {
      final file = File(targetPath);
      if (await file.exists()) await file.delete();
      throw Exception('下载失败：$e');
    } finally {
      client.close();
    }
  }

  /// 清理缓存
  Future<void> clearCache() async {
    final dir = Directory(cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
