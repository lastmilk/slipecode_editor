import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Flutter SDK 命令服务
///
/// 负责调用 flutter create 等命令来创建和管理 Flutter 项目
class FlutterService {
  /// 创建 Flutter 项目
  ///
  /// [projectName] 项目名称（snake_case）
  /// [targetPath] 项目将创建在哪个目录下
  /// [org] Android/iOS 的包名前缀
  /// [template] 模板类型：app, package, plugin
  Stream<String> createProject({
    required String projectName,
    required String targetPath,
    String org = 'com.example',
    String template = 'app',
  }) async* {
    final args = [
      'create',
      '--org',
      org,
      '--project-name',
      projectName,
      '--template',
      template,
      '--platforms=android',
      targetPath,
    ];

    yield '> flutter ${args.join(' ')}\n';

    final process = await Process.start(
      Platform.isWindows ? 'flutter.bat' : 'flutter',
      args,
    );

    final outputController = StreamController<String>();

    process.stdout.transform(utf8.decoder).listen((data) {
      for (final line in data.split('\n')) {
        outputController.add('$line\n');
      }
    });

    process.stderr.transform(utf8.decoder).listen((data) {
      for (final line in data.split('\n')) {
        outputController.add('[ERROR] $line\n');
      }
    });

    await for (final line in outputController.stream) {
      yield line;
    }

    final exitCode = await process.exitCode;
    yield '\nProcess exited with code: $exitCode';
    if (exitCode != 0) {
      throw Exception('flutter create failed with exit code $exitCode');
    }
  }
}
