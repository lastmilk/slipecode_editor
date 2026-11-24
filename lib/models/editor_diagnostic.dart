import 'text_position.dart';

/// 诊断级别
enum DiagnosticSeverity { error, warning, information, hint }

/// 编辑器诊断（语法 / 语义错误），供波浪线与「问题」面板使用
class EditorDiagnostic {
  final TextCoordinate start;
  final TextCoordinate end;
  final DiagnosticSeverity severity;
  final String message;
  final String? source;
  final String? filePath;

  const EditorDiagnostic({
    required this.start,
    required this.end,
    required this.message,
    this.severity = DiagnosticSeverity.error,
    this.source,
    this.filePath,
  });

  bool get isError => severity == DiagnosticSeverity.error;

  bool get isWarning => severity == DiagnosticSeverity.warning;

  EditorDiagnostic copyWith({String? filePath}) => EditorDiagnostic(
        start: start,
        end: end,
        severity: severity,
        message: message,
        source: source,
        filePath: filePath ?? this.filePath,
      );

  @override
  String toString() =>
      '${severity.name} $start-$end${source == null ? '' : ' ($source)'}: $message';
}
