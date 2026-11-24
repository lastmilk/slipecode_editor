import '../../models/text_position.dart';
import 'lsp_types.dart';

/// 语义分类（映射到语法高亮配色）
enum SemanticCategory {
  keyword,
  type,
  comment,
  string,
  number,
  function,
  variable,
  property,
  parameter,
  namespace,
  operator,
  annotation,
  other,
}

/// 绝对位置的语义 token
class SemanticTokenSpan {
  final int start;
  final int end;
  final SemanticCategory category;
  final String tokenType;

  const SemanticTokenSpan({
    required this.start,
    required this.end,
    required this.category,
    required this.tokenType,
  });
}

/// LSP token 类型 → 语义分类
SemanticCategory semanticCategoryFor(String tokenType) {
  switch (tokenType) {
    case 'keyword':
    case 'modifier':
      return SemanticCategory.keyword;
    case 'type':
    case 'class':
    case 'enum':
    case 'interface':
    case 'struct':
    case 'typeParameter':
    case 'typedef':
      return SemanticCategory.type;
    case 'comment':
      return SemanticCategory.comment;
    case 'string':
    case 'regexp':
      return SemanticCategory.string;
    case 'number':
      return SemanticCategory.number;
    case 'function':
    case 'method':
    case 'macro':
    case 'event':
      return SemanticCategory.function;
    case 'variable':
    case 'enumMember':
    case 'label':
      return SemanticCategory.variable;
    case 'property':
    case 'member':
      return SemanticCategory.property;
    case 'parameter':
      return SemanticCategory.parameter;
    case 'namespace':
    case 'package':
      return SemanticCategory.namespace;
    case 'operator':
      return SemanticCategory.operator;
    case 'annotation':
    case 'decorator':
      return SemanticCategory.annotation;
    default:
      return SemanticCategory.other;
  }
}

/// 把相对位置的语义 token 解码为字符串偏移区间
List<SemanticTokenSpan> semanticSpans(
  List<LspSemanticToken> tokens,
  String text,
) {
  if (tokens.isEmpty || text.isEmpty) return const [];
  final spans = <SemanticTokenSpan>[];
  for (final token in tokens) {
    if (token.length <= 0) continue;
    final start = TextCoordinate(token.line, token.character).toOffset(text);
    final end = (start + token.length).clamp(0, text.length);
    if (end <= start) continue;
    spans.add(
      SemanticTokenSpan(
        start: start,
        end: end,
        category: semanticCategoryFor(token.tokenType),
        tokenType: token.tokenType,
      ),
    );
  }
  return spans;
}
