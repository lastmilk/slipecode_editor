import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/editor_diagnostic.dart';
import '../../models/text_position.dart';
import 'json_rpc_connection.dart';
import 'lsp_client.dart';
import 'lsp_server_store.dart';
import 'lsp_types.dart';

/// 已同步文档
class LspDocumentState {
  final String path;
  final String languageId;
  final int version;
  final String text;

  const LspDocumentState({
    required this.path,
    required this.languageId,
    required this.version,
    required this.text,
  });
}

/// 一个「语言服务 + 工作区根」的会话。
///
/// 负责文档同步（full 同步）、诊断缓存与各类文本请求；
/// 请求失败统一返回 null，由上层回退到内置能力。
class LspSession {
  LspSession({
    required this.client,
    required this.rootPath,
    required this.config,
  });

  final LspClient client;
  final String rootPath;
  final LspServerConfig config;

  final Map<String, LspDocumentState> _documents = {};
  final Map<String, List<LspDiagnostic>> _diagnostics = {};

  /// 诊断回调：路径 → 编辑器诊断
  void Function(String path, List<EditorDiagnostic> diagnostics)? onDiagnostics;

  /// 服务端消息（window/showMessage 等）
  void Function(String message)? onServerMessage;

  /// 进度消息（$/progress）
  void Function(String message)? onProgress;

  Map<String, dynamic> serverCapabilities = const {};

  List<String> _tokenTypes = const [];

  String? lastError;

  String get id => client.id;

  bool get isRunning => client.isRunning;

  List<String> get tokenTypes => _tokenTypes;

  Map<String, List<LspDiagnostic>> get diagnostics =>
      Map.unmodifiable(_diagnostics);

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动并注册通知处理
  Future<void> start() async {
    client.onNotification = handleNotification;
    final result = await client.start(
      rootUri: uriForPath(rootPath),
      workspaceFolders: [uriForPath(rootPath)],
    );
    final capabilities = result['capabilities'];
    serverCapabilities = capabilities is Map
        ? capabilities.cast<String, dynamic>()
        : <String, dynamic>{};
    final legend = serverCapabilities['semanticTokensProvider'];
    if (legend is Map) {
      final types = legend['legend'];
      if (types is Map) {
        _tokenTypes = [
          for (final type in (types['tokenTypes'] as List? ?? const []))
            if (type is String) type,
        ];
      }
    }
  }

  Future<void> stop() async {
    _documents.clear();
    _diagnostics.clear();
    await client.stop();
  }

  // ---------------------------------------------------------------------------
  // 文档同步
  // ---------------------------------------------------------------------------

  bool isOpen(String path) => _documents.containsKey(path);

  String? documentText(String path) => _documents[path]?.text;

  void openDocument(String path, String text) {
    if (!client.isRunning) return;
    final existing = _documents[path];
    if (existing != null) {
      if (existing.text != text) changeDocument(path, text);
      return;
    }
    _documents[path] = LspDocumentState(
      path: path,
      languageId: config.languageId,
      version: 1,
      text: text,
    );
    client.connection?.notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uriForPath(path).toString(),
        'languageId': config.languageId,
        'version': 1,
        'text': text,
      },
    });
  }

  void changeDocument(String path, String text) {
    if (!client.isRunning) return;
    final existing = _documents[path];
    if (existing == null) {
      openDocument(path, text);
      return;
    }
    if (existing.text == text) return;
    final version = existing.version + 1;
    _documents[path] = LspDocumentState(
      path: path,
      languageId: existing.languageId,
      version: version,
      text: text,
    );
    client.connection?.notify('textDocument/didChange', {
      'textDocument': {
        'uri': uriForPath(path).toString(),
        'version': version,
      },
      'contentChanges': [
        {'text': text},
      ],
    });
  }

  void saveDocument(String path, {String? text}) {
    final existing = _documents[path];
    if (existing == null || !client.isRunning) return;
    if (text != null && existing.text != text) changeDocument(path, text);
    client.connection?.notify('textDocument/didSave', {
      'textDocument': {'uri': uriForPath(path).toString()},
    });
  }

  void closeDocument(String path) {
    final existing = _documents.remove(path);
    if (existing == null) return;
    _diagnostics.remove(path);
    client.connection?.notify('textDocument/didClose', {
      'textDocument': {'uri': uriForPath(path).toString()},
    });
  }

  // ---------------------------------------------------------------------------
  // 服务端通知
  // ---------------------------------------------------------------------------

  void handleNotification(String method, dynamic params) {
    switch (method) {
      case 'textDocument/publishDiagnostics':
        _handleDiagnostics(params);
      case 'window/showMessage':
        final message = (params as Map?)?['message'];
        if (message is String) onServerMessage?.call(message);
      case r'$/progress':
        final value = (params as Map?)?['value'];
        if (value is Map) {
          final kind = value['kind'];
          final message = value['message'] ?? value['title'];
          if (message is String) {
            onProgress?.call(kind == 'end' ? '' : message);
          }
        }
      case 'window/logMessage':
        final message = (params as Map?)?['message'];
        if (message is String) debugPrint('[LSP ${client.id}] $message');
    }
  }

  void _handleDiagnostics(dynamic params) {
    if (params is! Map) return;
    final uri = params['uri'];
    if (uri is! String) return;
    final path = pathForUri(uri);
    if (path == null) return;
    final raw = params['diagnostics'];
    final diagnostics = <LspDiagnostic>[
      for (final item in (raw is List ? raw : const []))
        if (item is Map) LspDiagnostic.fromJson(item.cast<String, dynamic>()),
    ];
    _diagnostics[path] = diagnostics;
    onDiagnostics?.call(path, [
      for (final item in diagnostics) item.toEditorDiagnostic(path),
    ]);
  }

  // ---------------------------------------------------------------------------
  // 文本请求
  // ---------------------------------------------------------------------------

  Future<List<LspCompletionItem>> completionAt(
    String path,
    LspPosition position,
  ) async {
    final result = await _request('textDocument/completion', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
      'context': {'triggerKind': 1},
    });
    if (result == null) return const [];
    final items = result is Map ? result['items'] : result;
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) LspCompletionItem.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<LspHover?> hoverAt(String path, LspPosition position) async {
    final result = await _request('textDocument/hover', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
    });
    if (result is! Map) return null;
    return LspHover.fromJson(result.cast<String, dynamic>());
  }

  Future<LspSignatureHelp?> signatureHelpAt(
    String path,
    LspPosition position,
  ) async {
    final result = await _request('textDocument/signatureHelp', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
    });
    if (result is! Map) return null;
    return LspSignatureHelp.fromJson(result.cast<String, dynamic>());
  }

  Future<List<LspLocation>> definitionAt(
    String path,
    LspPosition position,
  ) async {
    final result = await _request('textDocument/definition', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
    });
    if (result == null) return const [];
    final list = result is List ? result : [result];
    return [
      for (final item in list)
        if (item is Map) LspLocation.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<List<LspLocation>> referencesAt(
    String path,
    LspPosition position,
  ) async {
    final result = await _request('textDocument/references', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
      'context': {'includeDeclaration': true},
    });
    if (result is! List) return const [];
    return [
      for (final item in result)
        if (item is Map) LspLocation.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<LspWorkspaceEdit?> renameAt(
    String path,
    LspPosition position,
    String newName,
  ) async {
    final result = await _request('textDocument/rename', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'position': position.toJson(),
      'newName': newName,
    });
    if (result is! Map) return null;
    return LspWorkspaceEdit.fromJson(result.cast<String, dynamic>());
  }

  Future<List<LspTextEdit>> formatDocument(String path) async {
    final result = await _request('textDocument/formatting', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'options': {'tabSize': 2, 'insertSpaces': true},
    }, timeout: const Duration(seconds: 20));
    if (result is! List) return const [];
    return [
      for (final item in result)
        if (item is Map) LspTextEdit.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<List<LspCodeAction>> codeActionsAt(
    String path,
    LspRange range,
    List<LspDiagnostic> diagnostics,
  ) async {
    final result = await _request('textDocument/codeAction', {
      'textDocument': {'uri': uriForPath(path).toString()},
      'range': range.toJson(),
      'context': {
        'diagnostics': [
          for (final item in diagnostics)
            {
              'range': item.range.toJson(),
              'severity': item.severity,
              'message': item.message,
              if (item.source != null) 'source': item.source,
              if (item.code != null) 'code': item.code,
            },
        ],
        'only': null,
      },
    });
    if (result is! List) return const [];
    return [
      for (final item in result)
        if (item is Map) LspCodeAction.fromJson(item.cast<String, dynamic>()),
    ];
  }

  Future<List<LspDocumentSymbol>> documentSymbols(String path) async {
    final result = await _request('textDocument/documentSymbol', {
      'textDocument': {'uri': uriForPath(path).toString()},
    });
    if (result is! List) return const [];
    return [
      for (final item in result)
        if (item is Map)
          LspDocumentSymbol.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// 语义高亮 token
  Future<List<LspSemanticToken>> semanticTokens(String path) async {
    final result = await _request('textDocument/semanticTokens/full', {
      'textDocument': {'uri': uriForPath(path).toString()},
    });
    if (result is! Map) return const [];
    final data = result['data'];
    if (data is! List) return const [];
    return _decodeSemanticTokens(data);
  }

  List<LspSemanticToken> _decodeSemanticTokens(List<dynamic> data) {
    final tokens = <LspSemanticToken>[];
    var line = 0;
    var character = 0;
    for (var i = 0; i + 4 < data.length; i += 5) {
      final deltaLine = (data[i] as num?)?.toInt() ?? 0;
      final deltaStart = (data[i + 1] as num?)?.toInt() ?? 0;
      final length = (data[i + 2] as num?)?.toInt() ?? 0;
      final typeIndex = (data[i + 3] as num?)?.toInt() ?? 0;
      final modifiers = (data[i + 4] as num?)?.toInt() ?? 0;
      if (deltaLine > 0) {
        line += deltaLine;
        character = deltaStart;
      } else {
        character += deltaStart;
      }
      tokens.add(
        LspSemanticToken(
          line: line,
          character: character,
          length: length,
          tokenType: typeIndex < _tokenTypes.length
              ? _tokenTypes[typeIndex]
              : 'unknown',
          modifiers: modifiers,
        ),
      );
    }
    return tokens;
  }

  Future<dynamic> _request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final connection = client.connection;
    if (connection == null) return null;
    try {
      return await connection.request(method, params, timeout);
    } on JsonRpcException catch (e) {
      lastError = e.message;
      return null;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }
}

// -----------------------------------------------------------------------------
// 工具函数
// -----------------------------------------------------------------------------

/// 路径 → file URI（Windows 盘符 / 百分号编码）
Uri uriForPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  if (Platform.isWindows) {
    final normalized = absolute.replaceAll('\\', '/');
    return Uri(scheme: 'file', path: '/$normalized');
  }
  return Uri(scheme: 'file', path: absolute);
}

/// file URI → 路径
String? pathForUri(String uri) {
  try {
    final parsed = Uri.parse(uri);
    if (parsed.scheme != 'file') return null;
    var path = Uri.decodeFull(parsed.path);
    if (Platform.isWindows && path.startsWith('/') && path.length > 2) {
      path = path.substring(1);
    }
    return path;
  } catch (_) {
    return null;
  }
}

/// 把 LSP 文本编辑应用到一段文本（offset 从后往前应用，避免位移）
String applyLspTextEdits(String text, List<LspTextEdit> edits) {
  final sorted = List<LspTextEdit>.from(edits)
    ..sort((a, b) {
      final lineDiff = b.range.start.line.compareTo(a.range.start.line);
      if (lineDiff != 0) return lineDiff;
      return b.range.start.character.compareTo(a.range.start.character);
    });
  var result = text;
  for (final edit in sorted) {
    final start = edit.range.start.toCoordinate().toOffset(result);
    final end = edit.range.end.toCoordinate().toOffset(result);
    final safeStart = start.clamp(0, result.length);
    final safeEnd = end.clamp(safeStart, result.length);
    result = result.replaceRange(safeStart, safeEnd, edit.newText);
  }
  return result;
}

/// LSP 位置定位用：偏移 → LSP 位置
LspPosition lspPositionAt(String text, int offset) {
  final coordinate = TextCoordinate.fromOffset(text, offset);
  return LspPosition(coordinate.line, coordinate.character);
}
