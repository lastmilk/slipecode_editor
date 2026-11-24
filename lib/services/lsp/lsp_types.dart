import '../../models/editor_diagnostic.dart';
import '../../models/text_position.dart';

/// LSP 位置（0 基行 / 0 基 UTF-16 列）
class LspPosition {
  final int line;
  final int character;

  const LspPosition(this.line, this.character);

  factory LspPosition.fromJson(Map<String, dynamic> json) => LspPosition(
        (json['line'] as num?)?.toInt() ?? 0,
        (json['character'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'line': line,
        'character': character,
      };

  TextCoordinate toCoordinate() => TextCoordinate(line, character);

  @override
  String toString() => '$line:$character';
}

/// LSP 范围
class LspRange {
  final LspPosition start;
  final LspPosition end;

  const LspRange(this.start, this.end);

  factory LspRange.fromJson(Map<String, dynamic>? json) => LspRange(
        LspPosition.fromJson(
          (json?['start'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        LspPosition.fromJson(
          (json?['end'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );

  Map<String, dynamic> toJson() => {
        'start': start.toJson(),
        'end': end.toJson(),
      };
}

/// LSP 诊断
class LspDiagnostic {
  final LspRange range;
  final int severity;
  final String? code;
  final String? source;
  final String message;

  const LspDiagnostic({
    required this.range,
    required this.message,
    this.severity = 1,
    this.code,
    this.source,
  });

  factory LspDiagnostic.fromJson(Map<String, dynamic> json) => LspDiagnostic(
        range: LspRange.fromJson(
          (json['range'] as Map?)?.cast<String, dynamic>(),
        ),
        severity: (json['severity'] as num?)?.toInt() ?? 1,
        code: json['code']?.toString(),
        source: json['source'] as String?,
        message: (json['message'] as String?) ?? '',
      );

  DiagnosticSeverity get editorSeverity => switch (severity) {
        1 => DiagnosticSeverity.error,
        2 => DiagnosticSeverity.warning,
        3 => DiagnosticSeverity.information,
        _ => DiagnosticSeverity.hint,
      };

  EditorDiagnostic toEditorDiagnostic(String path) => EditorDiagnostic(
        start: range.start.toCoordinate(),
        end: range.end.toCoordinate(),
        severity: editorSeverity,
        message: message,
        source: source ?? code,
        filePath: path,
      );
}

/// LSP 位置（带文件 URI）
class LspLocation {
  final String uri;
  final LspRange range;

  const LspLocation({required this.uri, required this.range});

  factory LspLocation.fromJson(Map<String, dynamic> json) => LspLocation(
        uri: (json['uri'] as String?) ?? '',
        range: LspRange.fromJson(
          (json['range'] as Map?)?.cast<String, dynamic>(),
        ),
      );
}

/// 文本编辑（用于格式化 / Code Action / 重命名）
class LspTextEdit {
  final LspRange range;
  final String newText;

  const LspTextEdit({required this.range, required this.newText});

  factory LspTextEdit.fromJson(Map<String, dynamic> json) => LspTextEdit(
        range: LspRange.fromJson(
          (json['range'] as Map?)?.cast<String, dynamic>(),
        ),
        newText: (json['newText'] as String?) ?? '',
      );
}

/// 工作区编辑：按 URI 分组的多文件改动
class LspWorkspaceEdit {
  final Map<String, List<LspTextEdit>> changes;

  const LspWorkspaceEdit({required this.changes});

  bool get isEmpty => changes.values.every((edits) => edits.isEmpty);

  /// 解析 `WorkspaceEdit`（兼容 `changes` 与 `documentChanges` 两种形式）
  static LspWorkspaceEdit? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final changes = <String, List<LspTextEdit>>{};
    final rawChanges = json['changes'];
    if (rawChanges is Map) {
      rawChanges.forEach((uri, edits) {
        if (edits is! List) return;
        changes['$uri'] = [
          for (final edit in edits)
            if (edit is Map)
              LspTextEdit.fromJson(edit.cast<String, dynamic>()),
        ];
      });
    }
    final documentChanges = json['documentChanges'];
    if (documentChanges is List) {
      for (final change in documentChanges) {
        if (change is! Map) continue;
        final uri = (change['textDocument'] as Map?)?['uri'];
        final edits = change['edits'];
        if (uri is! String || edits is! List) continue;
        changes.putIfAbsent(uri, () => []).addAll([
          for (final edit in edits)
            if (edit is Map)
              LspTextEdit.fromJson(edit.cast<String, dynamic>()),
        ]);
      }
    }
    return LspWorkspaceEdit(changes: changes);
  }
}

/// 补全项
class LspCompletionItem {
  final String label;
  final int kind;
  final String? detail;
  final String? documentation;
  final String? insertText;
  final int insertTextFormat;
  final String? filterText;
  final String? sortText;
  final LspRange? textEditRange;
  final List<LspTextEdit> additionalTextEdits;
  final dynamic raw;

  const LspCompletionItem({
    required this.label,
    this.kind = 1,
    this.detail,
    this.documentation,
    this.insertText,
    this.insertTextFormat = 1,
    this.filterText,
    this.sortText,
    this.textEditRange,
    this.additionalTextEdits = const [],
    this.raw,
  });

  factory LspCompletionItem.fromJson(Map<String, dynamic> json) {
    final textEdit = json['textEdit'];
    LspRange? range;
    String? editText;
    if (textEdit is Map) {
      range = LspRange.fromJson(
        (textEdit['range'] as Map?)?.cast<String, dynamic>(),
      );
      editText = textEdit['newText'] as String?;
    }
    return LspCompletionItem(
      label: (json['label'] as String?) ?? '',
      kind: (json['kind'] as num?)?.toInt() ?? 1,
      detail: json['detail'] as String?,
      documentation: _documentation(json['documentation']),
      insertText: editText ?? json['insertText'] as String?,
      insertTextFormat: (json['insertTextFormat'] as num?)?.toInt() ?? 1,
      filterText: json['filterText'] as String?,
      sortText: json['sortText'] as String?,
      textEditRange: range,
      additionalTextEdits: [
        for (final edit in (json['additionalTextEdits'] as List? ?? const []))
          if (edit is Map) LspTextEdit.fromJson(edit.cast<String, dynamic>()),
      ],
      raw: json,
    );
  }
}

/// 悬停内容
class LspHover {
  final String contents;

  const LspHover(this.contents);

  bool get isEmpty => contents.trim().isEmpty;

  static LspHover? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return LspHover(_markdown(json['contents']));
  }
}

/// 签名帮助
class LspParameterInformation {
  final String label;

  const LspParameterInformation(this.label);

  factory LspParameterInformation.fromJson(dynamic json) {
    if (json is String) return LspParameterInformation(json);
    if (json is Map) {
      final label = json['label'];
      if (label is List && label.length == 2) {
        final start = (label[0] as num?)?.toInt() ?? 0;
        final end = (label[1] as num?)?.toInt() ?? start;
        return LspParameterInformation('[$start,$end]');
      }
      return LspParameterInformation('${label ?? ''}');
    }
    return const LspParameterInformation('');
  }
}

class LspSignature {
  final String label;
  final String? documentation;
  final List<LspParameterInformation> parameters;

  const LspSignature({
    required this.label,
    this.documentation,
    this.parameters = const [],
  });

  factory LspSignature.fromJson(Map<String, dynamic> json) => LspSignature(
        label: (json['label'] as String?) ?? '',
        documentation: _documentation(json['documentation']),
        parameters: [
          for (final item in (json['parameters'] as List? ?? const []))
            LspParameterInformation.fromJson(item),
        ],
      );
}

class LspSignatureHelp {
  final List<LspSignature> signatures;
  final int activeSignature;
  final int activeParameter;

  const LspSignatureHelp({
    required this.signatures,
    this.activeSignature = 0,
    this.activeParameter = 0,
  });

  bool get isEmpty => signatures.isEmpty;

  factory LspSignatureHelp.fromJson(Map<String, dynamic> json) =>
      LspSignatureHelp(
        signatures: [
          for (final item in (json['signatures'] as List? ?? const []))
            if (item is Map) LspSignature.fromJson(item.cast<String, dynamic>()),
        ],
        activeSignature: (json['activeSignature'] as num?)?.toInt() ?? 0,
        activeParameter: (json['activeParameter'] as num?)?.toInt() ?? 0,
      );
}

/// Code Action
class LspCodeAction {
  final String title;
  final String? kind;
  final bool isPreferred;
  final LspWorkspaceEdit? edit;
  final Map<String, dynamic>? command;

  const LspCodeAction({
    required this.title,
    this.kind,
    this.isPreferred = false,
    this.edit,
    this.command,
  });

  factory LspCodeAction.fromJson(Map<String, dynamic> json) {
    final edit = json['edit'];
    return LspCodeAction(
      title: (json['title'] as String?) ?? '',
      kind: json['kind'] as String?,
      isPreferred: json['isPreferred'] == true,
      edit: edit is Map
          ? LspWorkspaceEdit.fromJson(edit.cast<String, dynamic>())
          : null,
      command: (json['command'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

/// 文档符号
class LspDocumentSymbol {
  final String name;
  final String? detail;
  final int kind;
  final LspRange range;
  final LspRange selectionRange;
  final List<LspDocumentSymbol> children;

  const LspDocumentSymbol({
    required this.name,
    required this.kind,
    required this.range,
    required this.selectionRange,
    this.detail,
    this.children = const [],
  });

  factory LspDocumentSymbol.fromJson(Map<String, dynamic> json) {
    // 兼容 SymbolInformation（location 形式）
    final location = json['location'];
    final range = location is Map
        ? LspRange.fromJson((location['range'] as Map?)?.cast<String, dynamic>())
        : LspRange.fromJson((json['range'] as Map?)?.cast<String, dynamic>());
    return LspDocumentSymbol(
      name: (json['name'] as String?) ?? '',
      detail: json['detail'] as String?,
      kind: (json['kind'] as num?)?.toInt() ?? 13,
      range: range,
      selectionRange: LspRange.fromJson(
        (json['selectionRange'] as Map?)?.cast<String, dynamic>() ?? {},
      ),
      children: [
        for (final item in (json['children'] as List? ?? const []))
          if (item is Map)
            LspDocumentSymbol.fromJson(item.cast<String, dynamic>()),
      ],
    );
  }
}

/// 语义高亮 token（绝对行列）
class LspSemanticToken {
  final int line;
  final int character;
  final int length;
  final String tokenType;
  final int modifiers;

  const LspSemanticToken({
    required this.line,
    required this.character,
    required this.length,
    required this.tokenType,
    this.modifiers = 0,
  });
}

String _documentation(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is Map) {
    final map = value.cast<String, dynamic>();
    return (map['value'] ?? '').toString();
  }
  return value.toString();
}

String _markdown(dynamic contents) {
  if (contents == null) return '';
  if (contents is String) return contents;
  if (contents is Map) return _documentation(contents);
  if (contents is List) {
    final buffer = StringBuffer();
    for (final item in contents) {
      final text = item is Map ? _documentation(item) : '$item';
      if (text.trim().isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(text);
    }
    return buffer.toString();
  }
  return contents.toString();
}
