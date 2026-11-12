import 'dart:convert';

/// 知识库条目（私人经验 / 文档）
///
/// 可从官方文档复制，也可由 AI 在完成任务后（/expmod）自动写入。
class KnowledgeEntry {
  final String id;
  String title;
  String content;

  /// 来源：manual（手动）/ official（官方文档）/ ai（AI 经验）
  String source;

  /// 来源文档 id（官方文档复制时记录）
  String sourceId;

  List<String> tags;

  final DateTime createdAt;
  DateTime updatedAt;

  KnowledgeEntry({
    required this.id,
    required this.title,
    required this.content,
    this.source = 'manual',
    this.sourceId = '',
    List<String>? tags,
    required this.createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? [],
        updatedAt = updatedAt ?? createdAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'source': source,
        'sourceId': sourceId,
        'tags': tags,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory KnowledgeEntry.fromMap(Map<String, dynamic> map) {
    final created =
        DateTime.tryParse((map['createdAt'] ?? '').toString()) ??
            DateTime.now();
    return KnowledgeEntry(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      content: (map['content'] ?? '').toString(),
      source: (map['source'] ?? 'manual').toString(),
      sourceId: (map['sourceId'] ?? '').toString(),
      tags: ((map['tags'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      createdAt: created,
      updatedAt:
          DateTime.tryParse((map['updatedAt'] ?? '').toString()) ?? created,
    );
  }

  KnowledgeEntry copyWith({
    String? title,
    String? content,
    List<String>? tags,
    String? source,
    String? sourceId,
    DateTime? updatedAt,
  }) {
    final next = KnowledgeEntry(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      tags: tags ?? List<String>.from(this.tags),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
    return next;
  }

  String get preview {
    final text = content
        .replaceAll(RegExp(r'[#>*`\-\[\]()]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 90 ? '${text.substring(0, 90)}…' : text;
  }

  String toJson() => jsonEncode(toMap());
}
