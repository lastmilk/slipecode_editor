import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../desktop_platform.dart';
import '../toolchain/toolchain_environment.dart';
import 'local_build_models.dart';

/// 生成并执行本地构建命令。
///
/// 只使用「应用内工具链 + 系统工具」，不依赖云端；命令输出以行为单位回调。
class LocalBuildService {
  Process? _process;
  bool _cancelled = false;
  bool _exited = true;

  bool get isRunning => _process != null && !_exited;

  /// 当前（或最近一次）任务是否被用户取消
  bool get wasCancelled => _cancelled;

  /// 生成命令步骤（不执行）。
  Future<List<LocalBuildStep>> plan({
    required String projectPath,
    required LocalBuildTarget target,
    required LocalTaskKind kind,
  }) async {
    switch (target.payloadId) {
      case 'flutter':
        return _flutterSteps(projectPath, target, kind);
      case 'node':
      case 'taro':
        return _nodeSteps(projectPath, kind);
      case 'android':
        return _androidSteps(kind);
      case 'html':
        return _htmlSteps(kind);
      case 'custom':
        return _customSteps(projectPath, kind);
      case 'python':
        return _pythonSteps(projectPath, kind);
      case 'java':
        return _javaSteps(projectPath, kind);
      case 'cpp':
        return _cppSteps(projectPath, kind);
      default:
        throw LocalBuildException('暂不支持该项目的本地构建：${target.payloadId}');
    }
  }

  // ---------------------------------------------------------------------------
  // 各载荷命令
  // ---------------------------------------------------------------------------

  List<LocalBuildStep> _flutterSteps(
    String projectPath,
    LocalBuildTarget target,
    LocalTaskKind kind,
  ) {
    switch (kind) {
      case LocalTaskKind.build:
        final sub = target.flutterTarget;
        if (sub == null) throw const LocalBuildException('缺失 Flutter 构建目标');
        final platform = _flutterPlatformOf(sub);
        return [
          ..._ensurePlatformSteps(projectPath, platform),
          LocalBuildStep(
            name: '解析依赖',
            executable: 'flutter',
            args: const ['pub', 'get'],
          ),
          LocalBuildStep(
            name: '构建 ${target.label}',
            executable: 'flutter',
            args: [
              'build',
              sub,
              '--release',
              if (sub == 'ios') '--no-codesign',
            ],
          ),
        ];
      case LocalTaskKind.run:
        final platform = Platform.isMacOS
            ? 'macos'
            : Platform.isWindows
            ? 'windows'
            : 'linux';
        return [
          ..._ensurePlatformSteps(projectPath, platform),
          LocalBuildStep(
            name: '运行',
            executable: 'flutter',
            args: ['run', '-d', platform],
          ),
        ];
      case LocalTaskKind.test:
        return [
          LocalBuildStep(
            name: '测试',
            executable: 'flutter',
            args: const ['test'],
          ),
        ];
      case LocalTaskKind.analyze:
        return [
          LocalBuildStep(
            name: '静态分析',
            executable: 'flutter',
            args: const ['analyze'],
          ),
        ];
    }
  }

  // ---------------------------------------------------------------------------
  // Flutter 平台目录
  // ---------------------------------------------------------------------------

  /// Flutter 构建子命令 → 需要的平台工程目录
  static String? _flutterPlatformOf(String target) => switch (target) {
    'apk' || 'appbundle' || 'aab' => 'android',
    'ios' => 'ios',
    'web' => 'web',
    'linux' => 'linux',
    'windows' => 'windows',
    'macos' => 'macos',
    _ => null,
  };

  /// 平台目录缺失时补一条 `flutter create --platforms=<p> .`
  ///
  /// SLIPE 的内置模板只包含 lib/ 与配置文件，云端构建会自行初始化平台目录；
  /// 本地构建必须先把 android/ios/web/桌面目录补齐，否则会报
  /// “Failed to read file .../android/app/build.gradle”。
  List<LocalBuildStep> _ensurePlatformSteps(
    String projectPath,
    String? platform,
  ) {
    if (platform == null || platform.isEmpty) return const [];
    if (Directory(p.join(projectPath, platform)).existsSync()) return const [];
    final name = _flutterProjectName(projectPath);
    return [
      LocalBuildStep(
        name: '补齐 $platform 平台目录',
        executable: 'flutter',
        args: [
          'create',
          '--platforms=$platform',
          // --empty：不生成默认模板（避免给项目塞入引用不存在类的 widget_test.dart）
          '--empty',
          if (name != null) '--project-name=$name',
          '.',
        ],
      ),
    ];
  }

  /// 读取 pubspec.yaml 的包名（flutter create 需要合法的 Dart 包名）
  String? _flutterProjectName(String projectPath) {
    final file = File(p.join(projectPath, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    final pattern = RegExp(r'^name:\s*([A-Za-z_][A-Za-z0-9_]*)');
    for (final line in file.readAsLinesSync()) {
      final match = pattern.firstMatch(line.trim());
      if (match != null) return match.group(1);
    }
    return null;
  }

  List<LocalBuildStep> _nodeSteps(String projectPath, LocalTaskKind kind) {
    final scripts = _nodeScripts(projectPath);
    final install = File(p.join(projectPath, 'package-lock.json')).existsSync()
        ? LocalBuildStep(name: '安装依赖', executable: 'npm', args: const ['ci'])
        : LocalBuildStep(
            name: '安装依赖',
            executable: 'npm',
            args: const ['install'],
          );

    String? pick(List<String> names) {
      for (final name in names) {
        if (scripts.containsKey(name)) return name;
      }
      return null;
    }

    switch (kind) {
      case LocalTaskKind.build:
        final script = pick(const ['build']);
        if (script == null) {
          throw LocalBuildException(
            'package.json 没有 build 脚本（可用脚本：'
            '${scripts.keys.join(', ')}）',
          );
        }
        return [
          install,
          LocalBuildStep(name: '构建', executable: 'npm', args: ['run', script]),
        ];
      case LocalTaskKind.run:
        final script = pick(const ['dev', 'start', 'serve']);
        if (script == null) {
          throw LocalBuildException(
            'package.json 没有 dev / start 脚本（可用脚本：'
            '${scripts.keys.join(', ')}）',
          );
        }
        return [
          install,
          LocalBuildStep(
            name: '启动开发服务',
            executable: 'npm',
            args: ['run', script],
          ),
        ];
      case LocalTaskKind.test:
        final script = pick(const ['test']);
        if (script == null) {
          throw const LocalBuildException('package.json 没有 test 脚本');
        }
        return [
          LocalBuildStep(name: '测试', executable: 'npm', args: ['run', script]),
        ];
      case LocalTaskKind.analyze:
        final script = pick(const ['lint', 'typecheck', 'check']);
        if (script == null) {
          throw const LocalBuildException(
            'package.json 没有 lint / typecheck 脚本',
          );
        }
        return [
          LocalBuildStep(
            name: '代码检查',
            executable: 'npm',
            args: ['run', script],
          ),
        ];
    }
  }

  Map<String, String> _nodeScripts(String projectPath) {
    final file = File(p.join(projectPath, 'package.json'));
    if (!file.existsSync()) {
      throw const LocalBuildException('项目根目录缺少 package.json');
    }
    try {
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map) throw const LocalBuildException('package.json 格式不正确');
      final raw = data['scripts'];
      if (raw is! Map) return const {};
      return raw.map((key, value) => MapEntry('$key', '$value'));
    } catch (e) {
      if (e is LocalBuildException) rethrow;
      throw LocalBuildException('解析 package.json 失败：$e');
    }
  }

  List<LocalBuildStep> _androidSteps(LocalTaskKind kind) {
    final gradlew = Platform.isWindows ? 'gradlew.bat' : './gradlew';
    switch (kind) {
      case LocalTaskKind.build:
        return [
          LocalBuildStep(
            name: 'Gradle assembleRelease',
            executable: gradlew,
            args: const [':app:assembleRelease'],
          ),
        ];
      case LocalTaskKind.test:
        return [
          LocalBuildStep(
            name: 'Gradle test',
            executable: gradlew,
            args: const ['test'],
          ),
        ];
      case LocalTaskKind.run:
      case LocalTaskKind.analyze:
        throw const LocalBuildException('Android 原生项目暂不支持本地运行 / 分析');
    }
  }

  List<LocalBuildStep> _htmlSteps(LocalTaskKind kind) {
    switch (kind) {
      case LocalTaskKind.build:
        return const [];
      case LocalTaskKind.run:
        return const []; // 由本地预览服务处理
      case LocalTaskKind.test:
      case LocalTaskKind.analyze:
        throw const LocalBuildException('HTML 项目暂不支持测试 / 分析');
    }
  }

  List<LocalBuildStep> _customSteps(String projectPath, LocalTaskKind kind) {
    final file = File(p.join(projectPath, '.slipe.json'));
    if (!file.existsSync()) {
      throw const LocalBuildException('未找到 .slipe.json（自定义构建配置）');
    }
    Map<String, dynamic> data;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) throw const LocalBuildException('.slipe.json 需为对象');
      data = raw.cast<String, dynamic>();
    } catch (e) {
      if (e is LocalBuildException) rethrow;
      throw LocalBuildException('解析 .slipe.json 失败：$e');
    }
    final scripts = data['scripts'];
    final commands = scripts is Map ? scripts[kind.name] : null;
    final list = switch (commands) {
      String value => [value],
      List value => value.whereType<String>().toList(),
      _ => const <String>[],
    };
    if (list.isEmpty) {
      throw LocalBuildException('.slipe.json 缺少 scripts.${kind.name}');
    }
    final shell = Platform.isWindows ? 'cmd' : '/bin/sh';
    return [
      for (final command in list)
        LocalBuildStep(
          name: command,
          executable: shell,
          args: Platform.isWindows ? ['/c', command] : ['-lc', command],
          shell: true,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Python / Java / C++
  // ---------------------------------------------------------------------------

  String get _pythonExe => Platform.isWindows ? 'python' : 'python3';

  /// Python 入口：main.py / app.py / src/main.py
  String? _pythonEntry(String projectPath) {
    for (final candidate in const ['main.py', 'app.py', 'src/main.py']) {
      if (File(p.join(projectPath, candidate)).existsSync()) return candidate;
    }
    return null;
  }

  List<LocalBuildStep> _pythonSteps(String projectPath, LocalTaskKind kind) {
    final hasRequirements = File(p.join(projectPath, 'requirements.txt'))
        .existsSync();
    final install = LocalBuildStep(
      name: '安装依赖',
      executable: _pythonExe,
      args: const ['-m', 'pip', 'install', '-r', 'requirements.txt'],
    );

    switch (kind) {
      case LocalTaskKind.build:
        return [
          if (hasRequirements) install,
          LocalBuildStep(
            name: '语法检查',
            executable: _pythonExe,
            args: const ['-m', 'compileall', '-q', '.'],
          ),
        ];
      case LocalTaskKind.run:
        final entry = _pythonEntry(projectPath);
        if (entry == null) {
          throw const LocalBuildException(
            '未找到入口文件（main.py / app.py / src/main.py）',
          );
        }
        return [
          if (hasRequirements) install,
          LocalBuildStep(
            name: '运行 $entry',
            executable: _pythonExe,
            args: [entry],
          ),
        ];
      case LocalTaskKind.test:
        return [
          if (hasRequirements) install,
          LocalBuildStep(
            name: 'pytest',
            executable: _pythonExe,
            args: const ['-m', 'pytest', '-q'],
          ),
        ];
      case LocalTaskKind.analyze:
        return [
          LocalBuildStep(
            name: '语法检查',
            executable: _pythonExe,
            args: const ['-m', 'compileall', '-q', '.'],
          ),
        ];
    }
  }

  /// Java 构建工具：Gradle Wrapper > Maven > 系统 Gradle
  String _javaBuildTool(String projectPath) {
    final wrapper = p.join(
      projectPath,
      'gradlew${Platform.isWindows ? '.bat' : ''}',
    );
    if (File(wrapper).existsSync()) return 'wrapper';
    if (File(p.join(projectPath, 'pom.xml')).existsSync()) return 'maven';
    if (File(p.join(projectPath, 'build.gradle')).existsSync() ||
        File(p.join(projectPath, 'build.gradle.kts')).existsSync()) {
      return 'gradle';
    }
    throw const LocalBuildException(
      '未找到 pom.xml / build.gradle，无法确定 Java 构建工具',
    );
  }

  List<LocalBuildStep> _javaSteps(String projectPath, LocalTaskKind kind) {
    final tool = _javaBuildTool(projectPath);
    final isMaven = tool == 'maven';
    final gradle = tool == 'wrapper'
        ? (Platform.isWindows ? 'gradlew.bat' : './gradlew')
        : 'gradle';

    // 非 Wrapper 项目需要系统已安装对应构建工具
    if (tool != 'wrapper' &&
        !ToolchainEnvironment.hasOnPath(isMaven ? 'mvn' : 'gradle')) {
      throw LocalBuildException(
        isMaven
            ? '未找到 Maven（mvn），请先安装或在项目中添加 mvnw'
            : '未找到 Gradle（gradle），请先安装或在项目中添加 gradlew',
      );
    }

    LocalBuildStep step(
      String name,
      List<String> gradleArgs,
      List<String> mavenArgs,
    ) => LocalBuildStep(
      name: name,
      executable: isMaven ? 'mvn' : gradle,
      args: isMaven ? mavenArgs : gradleArgs,
    );

    switch (kind) {
      case LocalTaskKind.build:
        return [
          step('构建 jar', const ['build'], const ['-B', '-q', 'package']),
        ];
      case LocalTaskKind.run:
        return [
          step('运行', const ['run'], const ['-q', 'exec:java']),
        ];
      case LocalTaskKind.test:
        return [
          step('测试', const ['test'], const ['-B', 'test']),
        ];
      case LocalTaskKind.analyze:
        return [
          step('编译检查', const ['compileJava'], const ['-B', '-q', 'compile']),
        ];
    }
  }

  List<LocalBuildStep> _cppSteps(String projectPath, LocalTaskKind kind) {
    final hasMake = File(p.join(projectPath, 'Makefile')).existsSync();
    final hasCmake = File(p.join(projectPath, 'CMakeLists.txt')).existsSync();
    if (!hasMake && !hasCmake) {
      throw const LocalBuildException('未找到 Makefile / CMakeLists.txt');
    }

    switch (kind) {
      case LocalTaskKind.build:
        return hasMake
            ? [LocalBuildStep(name: 'make', executable: 'make', args: const [])]
            : [
                LocalBuildStep(
                  name: 'CMake 配置',
                  executable: 'cmake',
                  args: const ['-B', 'build', '-DCMAKE_BUILD_TYPE=Release'],
                ),
                LocalBuildStep(
                  name: 'CMake 构建',
                  executable: 'cmake',
                  args: const ['--build', 'build', '-j'],
                ),
              ];
      case LocalTaskKind.run:
        if (hasMake) {
          return [
            LocalBuildStep(
              name: '构建并运行',
              executable: 'make',
              args: const ['run'],
            ),
          ];
        }
        throw const LocalBuildException('CMake 项目请在终端中运行构建产物');
      case LocalTaskKind.test:
        if (hasMake) {
          return [
            LocalBuildStep(
              name: 'make test',
              executable: 'make',
              args: const ['test'],
            ),
          ];
        }
        throw const LocalBuildException('CMake 项目暂不支持本地测试');
      case LocalTaskKind.analyze:
        return hasMake
            ? [
                LocalBuildStep(
                  name: '编译检查',
                  executable: 'make',
                  args: const ['-n'],
                ),
              ]
            : [
                LocalBuildStep(
                  name: 'CMake 配置',
                  executable: 'cmake',
                  args: const ['-B', 'build', '-DCMAKE_BUILD_TYPE=Release'],
                ),
              ];
    }
  }

  // ---------------------------------------------------------------------------
  // 执行
  // ---------------------------------------------------------------------------

  /// 顺序执行 [task] 的步骤，返回退出码（0 表示成功）。
  Future<int> execute({
    required LocalBuildTask task,
    required Map<String, String> environment,
    required void Function(String line) onLog,
    required void Function() onUpdate,
  }) async {
    _cancelled = false;
    if (task.steps.isEmpty) {
      onLog('（无需要执行的命令）');
      return 0;
    }
    for (final step in task.steps) {
      if (_cancelled) {
        step.status = LocalStepStatus.skipped;
        onUpdate();
        continue;
      }
      step.status = LocalStepStatus.running;
      step.startedAt = DateTime.now();
      onUpdate();
      onLog('\$ ${step.displayCommand}');

      final exitCode = await _runStep(
        step: step,
        workingDirectory: task.projectPath,
        environment: environment,
        onLog: onLog,
      );
      step.exitCode = exitCode;
      step.finishedAt = DateTime.now();
      if (exitCode != 0) {
        step.status = _cancelled
            ? LocalStepStatus.skipped
            : LocalStepStatus.failed;
        onUpdate();
        onLog('[步骤失败] ${step.name}（exit $exitCode）');
        return exitCode;
      }
      if (_cancelled) {
        step.status = LocalStepStatus.skipped;
        onUpdate();
        return -1;
      }
      step.status = LocalStepStatus.success;
      onUpdate();
    }
    return 0;
  }

  Future<int> _runStep({
    required LocalBuildStep step,
    required String workingDirectory,
    required Map<String, String> environment,
    required void Function(String line) onLog,
  }) async {
    try {
      final process = await Process.start(
        step.executable,
        step.args,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: Platform.isWindows && step.executable.endsWith('.bat'),
      );
      _process = process;
      _exited = false;

      var stdoutDone = Future<void>.value();
      var stderrDone = Future<void>.value();
      stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => onLog(_clean(line)))
          .asFuture<void>();
      stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => onLog(_clean(line)))
          .asFuture<void>();

      final exitCode = await process.exitCode;
      _exited = true;
      await Future.wait([stdoutDone, stderrDone]);
      _process = null;
      return exitCode;
    } on ProcessException catch (e) {
      _exited = true;
      _process = null;
      onLog('[无法启动 ${step.executable}] ${e.message}');
      return 127;
    }
  }

  /// 取消当前任务（先 SIGTERM，2 秒后 SIGKILL）。
  void cancel() {
    _cancelled = true;
    final process = _process;
    if (process == null || _exited) return;
    if (Platform.isWindows) {
      unawaited(
        Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']),
      );
      return;
    }
    try {
      Process.killPid(-process.pid, ProcessSignal.sigterm);
    } catch (_) {
      process.kill(ProcessSignal.sigterm);
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (_process == process && !_exited) {
        try {
          Process.killPid(-process.pid, ProcessSignal.sigkill);
        } catch (_) {
          process.kill(ProcessSignal.sigkill);
        }
      }
    });
  }

  static final RegExp _ansiPattern = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

  String _clean(String line) =>
      line.replaceAll(_ansiPattern, '').replaceAll('\r', '');

  /// 打开产物所在目录（桌面）。
  Future<void> reveal(String path) => DesktopPlatform.revealInFileManager(path);
}
