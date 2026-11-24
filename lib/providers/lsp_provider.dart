import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/editor_diagnostic.dart';
import '../providers/editor_provider.dart';
import '../services/completion_service.dart';
import '../services/desktop_prefs_service.dart';
import '../services/lsp/lsp_manager.dart';
import '../services/lsp/lsp_session.dart';
import '../services/lsp/lsp_types.dart';
import '../services/lsp/semantic_tokens.dart';

/// LSP 能力入口
///
/// 负责工作区生命周期、文档同步、请求转发与语义高亮缓存；
/// LSP 不可用时各 API 返回空值，由编辑器回退到内置能力。
class LspProvider extends ChangeNotifier {
  LspProvider({required EditorProvider editorProvider})
    : _editorProvider = editorProvider {
    final manager = LspManager.instance;
    manager.addListener(_onManagerChanged);
    manager.onDiagnostics = (path, diagnostics) {
      _editorProvider.setDiagnostics(path, diagnostics);
      _scheduleSemanticRefresh(path);
    };
    manager.onMessage = (message) {
      _appendLog(message);
    };
  }

  final EditorProvider _editorProvider;
  final LspManager _manager = LspManager.instance;

  /// 诊断摘要缓存（用于问题面板计数以外的地方）
  final Map<String, List<EditorDiagnostic>> _diagnostics = {};

  /// 每个文件的语义高亮
  final Map<String, List<SemanticTokenSpan>> _semanticTokens = {};
  final Map<String, Timer> _semanticDebounce = {};

  /// 运行日志（展示于「查看日志」）
  final List<String> _logs = [];

  String? _progress;
  bool _enabled = DesktopPrefsService.instance.lspEnabled;
  String? _rootPath;

  // ---------------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------------

  LspManagerState get state =>
      _enabled ? _manager.state : LspManagerState.disabled;

  bool get enabled => _enabled;

  bool get isReady => state == LspManagerState.running;

  String? get error => _manager.error;

  String? get dartVersion => _manager.dartVersion;

  String? get progress => _progress ?? _manager.progress;

  String? get rootPath => _rootPath;

  List<String> get logs => List.unmodifiable(_logs);

  List<SemanticTokenSpan> semanticTokensFor(String path) =>
      _semanticTokens[path] ?? const [];

  /// 状态栏展示文案的 i18n key
  String get statusKey => switch (state) {
    LspManagerState.running => 'desktop.status.lspReady',
    LspManagerState.starting => 'desktop.status.lspStarting',
    LspManagerState.failed => 'desktop.status.lspFailed',
    LspManagerState.disabled => 'desktop.status.lspOff',
    LspManagerState.stopped => 'desktop.status.lspOff',
  };

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 切换工作区（项目打开 / 关闭时调用）
  Future<void> setProject(String? projectPath) async {
    debugPrint(
      'LSP: setProject($projectPath) enabled=$_enabled root=$_rootPath',
    );
    if (_rootPath == projectPath) return;
    _rootPath = projectPath;
    _semanticTokens.clear();
    _diagnostics.clear();
    if (projectPath == null) {
      await _manager.stop();
      _editorProvider.clearDiagnostics();
      notifyListeners();
      return;
    }
    if (!_enabled) {
      notifyListeners();
      return;
    }
    notifyListeners();
    await _manager.startProject(projectPath);
  }

  /// 重启当前工作区（状态栏 / 设置页）
  Future<void> restart() async {
    if (!_enabled) return;
    _semanticTokens.clear();
    await _manager.restart();
    notifyListeners();
  }

  /// 用户设置总开关：只保存基础值，再应用当前有效状态。
  Future<void> setEnabled(bool value) async {
    DesktopPrefsService.instance.update(() {
      DesktopPrefsService.instance.lspEnabled = value;
    });
    await applyEffectiveEnabled(DesktopPrefsService.instance.lspEnabled);
  }

  /// Lua 覆盖层热重载时更新运行状态，不回写基础偏好。
  Future<void> applyEffectiveEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    if (!value) {
      await _manager.stop();
      _editorProvider.clearDiagnostics();
      _semanticTokens.clear();
      notifyListeners();
      return;
    }
    final root = _rootPath;
    if (root != null) await _manager.startProject(root, force: true);
    notifyListeners();
  }

  void _onManagerChanged() {
    if (_manager.state == LspManagerState.running) {
      // 服务就绪后为已打开文档补齐语义高亮
      for (final path in _editorProvider.openFiles.map((file) => file.path)) {
        _scheduleSemanticRefresh(path);
      }
    }
    notifyListeners();
  }

  void _appendLog(String message) {
    final line = message.trim();
    if (line.isEmpty) return;
    _logs.add(line);
    if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 文档同步
  // ---------------------------------------------------------------------------

  LspSession? _sessionFor(String path) => _manager.sessionForPath(path);

  /// 确保文档已同步（幂等，可在 build 中调用）
  void ensureDocument(String path, String text) {
    if (!_enabled) return;
    final session = _sessionFor(path);
    if (session == null) return;
    if (!session.isOpen(path)) {
      session.openDocument(path, text);
      _scheduleSemanticRefresh(path);
      return;
    }
    if (session.documentText(path) != text) {
      session.changeDocument(path, text);
    }
  }

  /// 内容变更（编辑器输入）
  void didChange(String path, String text) {
    if (!_enabled) return;
    final session = _sessionFor(path);
    if (session == null) return;
    session.changeDocument(path, text);
  }

  /// 保存
  void didSave(String path, String text) {
    if (!_enabled) return;
    final session = _sessionFor(path);
    session?.saveDocument(path, text: text);
  }

  /// 关闭文档
  void closeDocument(String path) {
    final session = _sessionFor(path);
    session?.closeDocument(path);
    _semanticTokens.remove(path);
    _diagnostics.remove(path);
    _semanticDebounce.remove(path)?.cancel();
    _editorProvider.clearDiagnostics(path);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 补全 / 悬停 / 跳转
  // ---------------------------------------------------------------------------

  /// LSP 补全；返回空列表表示不可用（回退内置补全）
  Future<List<CompletionItem>> completionAt(
    String path,
    String text,
    int offset,
  ) async {
    if (!isReady || text.length > 512 * 1024) return const [];
    final session = _sessionFor(path);
    if (session == null) return const [];
    ensureDocument(path, text);
    final items = await session.completionAt(path, lspPositionAt(text, offset));
    if (items.isEmpty) return const [];
    return [for (final item in items.take(200)) _toCompletionItem(item)];
  }

  Future<LspHover?> hoverAt(String path, String text, int offset) async {
    if (!isReady) return null;
    final session = _sessionFor(path);
    if (session == null) return null;
    return session.hoverAt(path, lspPositionAt(text, offset));
  }

  Future<LspSignatureHelp?> signatureHelpAt(
    String path,
    String text,
    int offset,
  ) async {
    if (!isReady) return null;
    final session = _sessionFor(path);
    if (session == null) return null;
    return session.signatureHelpAt(path, lspPositionAt(text, offset));
  }

  /// 跳转定义：返回 (路径, 1 基行, 1 基列)
  Future<(String, int, int)?> definitionAt(
    String path,
    String text,
    int offset,
  ) async {
    if (!isReady) return null;
    final session = _sessionFor(path);
    if (session == null) return null;
    final locations = await session.definitionAt(
      path,
      lspPositionAt(text, offset),
    );
    if (locations.isEmpty) return null;
    final target = locations.first;
    final targetPath = pathForUri(target.uri);
    if (targetPath == null) return null;
    return (
      targetPath,
      target.range.start.line + 1,
      target.range.start.character + 1,
    );
  }

  /// 引用查找：返回 (路径, 1 基行, 1 基列) 列表
  Future<List<(String, int, int)>> referencesAt(
    String path,
    String text,
    int offset,
  ) async {
    if (!isReady) return const [];
    final session = _sessionFor(path);
    if (session == null) return const [];
    final locations = await session.referencesAt(
      path,
      lspPositionAt(text, offset),
    );
    final result = <(String, int, int)>[];
    for (final location in locations) {
      final targetPath = pathForUri(location.uri);
      if (targetPath == null) continue;
      result.add((
        targetPath,
        location.range.start.line + 1,
        location.range.start.character + 1,
      ));
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 重命名 / 格式化 / Code Action
  // ---------------------------------------------------------------------------

  Future<LspWorkspaceEdit?> renameAt(
    String path,
    String text,
    int offset,
    String newName,
  ) async {
    if (!isReady || newName.trim().isEmpty) return null;
    final session = _sessionFor(path);
    if (session == null) return null;
    return session.renameAt(path, lspPositionAt(text, offset), newName.trim());
  }

  /// 文档格式化；返回 null 表示无改动或不可用
  Future<String?> formatDocument(String path, String text) async {
    if (!isReady) return null;
    final session = _sessionFor(path);
    if (session == null) return null;
    final edits = await session.formatDocument(path);
    if (edits.isEmpty) return null;
    final updated = applyLspTextEdits(text, edits);
    return updated == text ? null : updated;
  }

  Future<List<LspCodeAction>> codeActionsAt(
    String path,
    String text,
    int startOffset,
    int endOffset,
  ) async {
    if (!isReady) return const [];
    final session = _sessionFor(path);
    if (session == null) return const [];
    final diagnostics = _editorProvider
        .diagnosticsFor(path)
        .map(
          (diagnostic) => LspDiagnostic(
            range: LspRange(
              LspPosition(diagnostic.start.line, diagnostic.start.character),
              LspPosition(diagnostic.end.line, diagnostic.end.character),
            ),
            severity: _severityCode(diagnostic.severity),
            message: diagnostic.message,
            source: diagnostic.source,
          ),
        )
        .toList();
    return session.codeActionsAt(
      path,
      LspRange(
        lspPositionAt(text, startOffset),
        lspPositionAt(text, endOffset),
      ),
      diagnostics,
    );
  }

  /// 应用工作区编辑：已打开文件标记为脏，其余文件直接落盘
  Future<List<String>> applyWorkspaceEdit(LspWorkspaceEdit edit) async {
    final changed = <String>[];
    for (final entry in edit.changes.entries) {
      final path = pathForUri(entry.key);
      if (path == null || entry.value.isEmpty) continue;
      final open = _editorProvider.openFiles
          .where((file) => file.path == path)
          .firstOrNull;
      String original;
      if (open != null) {
        original = open.content;
      } else {
        try {
          original = await File(path).readAsString();
        } catch (_) {
          continue;
        }
      }
      final updated = applyLspTextEdits(original, entry.value);
      if (updated == original) continue;
      if (open != null) {
        _editorProvider.replaceContent(path, updated);
        didChange(path, updated);
      } else {
        try {
          await File(path).writeAsString(updated);
        } catch (_) {
          continue;
        }
      }
      changed.add(path);
    }
    if (changed.isNotEmpty) notifyListeners();
    return changed;
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 语义高亮
  // ---------------------------------------------------------------------------

  void _scheduleSemanticRefresh(String path) {
    _semanticDebounce[path]?.cancel();
    _semanticDebounce[path] = Timer(const Duration(milliseconds: 400), () {
      unawaited(_refreshSemanticTokens(path));
    });
  }

  Future<void> _refreshSemanticTokens(String path) async {
    if (!isReady) return;
    final session = _sessionFor(path);
    if (session == null) return;
    final text = session.documentText(path);
    if (text == null || text.isEmpty) return;
    final tokens = await session.semanticTokens(path);
    if (tokens.isEmpty) return;
    final spans = semanticSpans(tokens, text);
    if (spans.isEmpty) return;
    _semanticTokens[path] = spans;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  CompletionItem _toCompletionItem(LspCompletionItem item) {
    final raw = item.insertText ?? item.label;
    final insert = item.insertTextFormat == 2 ? _snippetText(raw) : raw;
    return CompletionItem(
      insertText: insert.isEmpty ? item.label : insert,
      label: item.label,
      kindLabel: _kindLabel(item.kind),
      detail: item.detail,
      kind: _completionKind(item.kind),
    );
  }

  /// LSP snippet → 纯文本（占位符替换为默认值）
  static String _snippetText(String snippet) {
    var text = snippet.replaceAllMapped(
      RegExp(r'\$\{\d+:([^}]*)\}'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAll(RegExp(r'\$\{\d+\}'), '');
    text = text.replaceAll(RegExp(r'\$\d+'), '');
    // 转义字符
    return text
        .replaceAll(r'\$', r'$')
        .replaceAll(r'\}', '}')
        .replaceAll(r'\{', '{');
  }

  static CompletionKind _completionKind(int kind) => switch (kind) {
    14 => CompletionKind.keyword,
    15 => CompletionKind.snippet,
    2 || 3 || 4 => CompletionKind.member,
    5 || 6 || 10 || 20 || 21 || 12 => CompletionKind.identifier,
    7 || 8 || 9 || 13 || 22 || 25 => CompletionKind.identifier,
    _ => CompletionKind.identifier,
  };

  static String _kindLabel(int kind) => switch (kind) {
    2 => '方法',
    3 => '函数',
    4 => '构造函数',
    5 => '字段',
    6 => '变量',
    7 => '类',
    8 => '接口',
    9 => '模块',
    10 => '属性',
    11 => '单元',
    12 => '值',
    13 => '枚举',
    14 => '关键字',
    15 => '片段',
    16 => '颜色',
    17 => '文件',
    18 => '引用',
    19 => '目录',
    20 => '枚举值',
    21 => '常量',
    22 => '结构体',
    23 => '事件',
    24 => '运算符',
    25 => '类型参数',
    _ => '文本',
  };

  static int _severityCode(DiagnosticSeverity severity) => switch (severity) {
    DiagnosticSeverity.error => 1,
    DiagnosticSeverity.warning => 2,
    DiagnosticSeverity.information => 3,
    DiagnosticSeverity.hint => 4,
  };

  @override
  void dispose() {
    final manager = LspManager.instance;
    manager.removeListener(_onManagerChanged);
    for (final timer in _semanticDebounce.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
