import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'json_rpc_connection.dart';

/// 客户端状态
enum LspClientState { stopped, starting, running, failed }

/// 语言服务启动参数
class LspLaunchSpec {
  final String id;
  final String name;
  final String executable;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String> environment;
  final Map<String, dynamic>? initializationOptions;
  final String? version;

  const LspLaunchSpec({
    required this.id,
    required this.name,
    required this.executable,
    this.args = const [],
    this.workingDirectory,
    this.environment = const {},
    this.initializationOptions,
    this.version,
  });
}

/// 单个语言服务进程：握手 / 关闭 / 状态机
class LspClient {
  LspClient(this.spec);

  final LspLaunchSpec spec;

  Process? _process;
  JsonRpcConnection? _connection;
  StreamSubscription<String>? _stderrSub;

  LspClientState state = LspClientState.stopped;
  String? error;
  int? exitCode;

  /// 服务端通知回调
  void Function(String method, dynamic params)? onNotification;

  /// 进程退出回调（非主动关闭时用于自动重启）
  void Function(int? code)? onExit;

  bool get isRunning => state == LspClientState.running;

  JsonRpcConnection? get connection => _connection;

  String get id => spec.id;

  String get name => spec.name;

  /// 启动并完成 initialize / initialized 握手
  Future<Map<String, dynamic>> start({
    required Uri rootUri,
    required List<Uri> workspaceFolders,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (state == LspClientState.running) {
      return const <String, dynamic>{};
    }
    await stop();
    state = LspClientState.starting;
    error = null;
    exitCode = null;

    final environment = <String, String>{
      ...Platform.environment,
      ...spec.environment,
    };
    final process = await Process.start(
      spec.executable,
      spec.args,
      workingDirectory: spec.workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
    );
    _process = process;

    _stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      debugPrint('[LSP ${spec.id}] $line');
    });

    final connection = JsonRpcConnection(
      process.stdout,
      (data) => _write(process, data),
      defaultTimeout: const Duration(seconds: 20),
      onNotification: (method, params) => onNotification?.call(method, params),
      onServerRequest: _handleServerRequest,
      onLog: (line) => debugPrint('[LSP ${spec.id}] $line'),
    );
    _connection = connection;

    unawaited(process.exitCode.then((code) {
      exitCode = code;
      final wasRunning = state == LspClientState.running;
      state = LspClientState.stopped;
      _connection?.dispose();
      _connection = null;
      if (wasRunning) onExit?.call(code);
    }));

    try {
      final rootPath = _uriToPath(rootUri) ?? '';
      final result = await connection.request(
        'initialize',
        {
          'processId': pid,
          'clientInfo': {'name': 'SLIPE', 'version': '1.0'},
          'rootUri': rootUri.toString(),
          'rootPath': rootPath,
          'workspaceFolders': [
            for (final folder in workspaceFolders)
              {'uri': folder.toString(), 'name': _uriToPath(folder) ?? ''},
          ],
          'capabilities': clientCapabilities,
          if (spec.initializationOptions != null)
            'initializationOptions': spec.initializationOptions,
          'trace': 'off',
        },
        timeout,
      );
      connection.notify('initialized', const <String, dynamic>{});
      state = LspClientState.running;
      return (result is Map) ? result.cast<String, dynamic>() : <String, dynamic>{};
    } catch (e) {
      state = LspClientState.failed;
      error = '$e';
      await stop();
      rethrow;
    }
  }

  /// 关闭：shutdown 请求 → exit 通知 → 进程兜底终止
  Future<void> stop() async {
    final connection = _connection;
    final process = _process;
    _connection = null;
    _process = null;
    if (connection != null) {
      try {
        if (state == LspClientState.running) {
          await connection
              .request('shutdown', null, const Duration(seconds: 3))
              .timeout(const Duration(seconds: 4));
        }
        connection.notify('exit', null);
      } catch (_) {
        // 忽略关闭异常
      }
      connection.dispose();
    }
    await _stderrSub?.cancel();
    _stderrSub = null;
    if (process != null) {
      try {
        if (Platform.isWindows) {
          process.kill();
        } else {
          process.kill(ProcessSignal.sigterm);
          await process.exitCode.timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              process.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
      } catch (_) {
        // 进程可能已退出
      }
    }
    if (state != LspClientState.failed) state = LspClientState.stopped;
  }

  void _write(Process process, List<int> data) {
    try {
      process.stdin.add(Uint8List.fromList(data));
    } catch (e) {
      debugPrint('[LSP ${spec.id}] 写入失败：$e');
    }
  }

  Future<dynamic> _handleServerRequest(String method, dynamic params) async {
    switch (method) {
      case 'workspace/configuration':
        final items = (params as Map?)?['items'];
        if (items is List) return List<dynamic>.filled(items.length, null);
        return <dynamic>[];
      case 'workspace/applyEdit':
        return {'applied': false};
      case 'client/registerCapability':
      case 'client/unregisterCapability':
        return null;
      case 'window/showMessageRequest':
        return null;
      case 'window/workDoneProgress/create':
        return null;
      case 'workspace/workspaceFolders':
        return <dynamic>[];
      default:
        return null;
    }
  }

  /// 客户端 capabilities（关键项见实施计划）
  static const Map<String, dynamic> clientCapabilities = {
    'workspace': {
      'applyEdit': true,
      'workspaceEdit': {'documentChanges': true},
      'workspaceFolders': true,
      'configuration': true,
      'didChangeWatchedFiles': {'dynamicRegistration': false},
      'symbol': {
        'symbolKind': {'valueSet': []},
      },
    },
    'textDocument': {
      'synchronization': {
        'dynamicRegistration': false,
        'willSave': false,
        'willSaveWaitUntil': false,
        'didSave': true,
      },
      'completion': {
        'dynamicRegistration': false,
        'snippetSupport': true,
        'documentationFormat': ['markdown', 'plaintext'],
        'completionItemKind': {'valueSet': []},
      },
      'hover': {
        'dynamicRegistration': false,
        'contentFormat': ['markdown', 'plaintext'],
      },
      'signatureHelp': {
        'dynamicRegistration': false,
        'signatureInformation': {
          'documentationFormat': ['markdown', 'plaintext'],
        },
      },
      'definition': {'dynamicRegistration': false, 'linkSupport': false},
      'references': {'dynamicRegistration': false},
      'documentSymbol': {
        'dynamicRegistration': false,
        'hierarchicalDocumentSymbolSupport': true,
      },
      'formatting': {'dynamicRegistration': false},
      'rename': {'dynamicRegistration': false, 'prepareSupport': true},
      'codeAction': {
        'dynamicRegistration': false,
        'codeActionLiteralSupport': {
          'codeActionKind': {'valueSet': ['quickfix', 'refactor', 'source']},
        },
      },
      'publishDiagnostics': {
        'relatedInformation': true,
        'versionSupport': true,
      },
      'semanticTokens': {
        'dynamicRegistration': false,
        'requests': {'range': false, 'full': true},
        'tokenTypes': [],
        'tokenModifiers': [],
        'formats': ['relative'],
      },
    },
    'general': {
      'positionEncodings': ['utf-16'],
    },
  };

  static String? _uriToPath(Uri uri) {
    if (uri.scheme != 'file') return null;
    var path = Uri.decodeFull(uri.path);
    if (Platform.isWindows && path.startsWith('/') && path.length > 2) {
      path = path.substring(1);
    }
    return path;
  }
}
