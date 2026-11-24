import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ProjectSearchMatch {
  final String path;
  final int line;
  final int column;
  final String preview;

  const ProjectSearchMatch({
    required this.path,
    required this.line,
    required this.column,
    required this.preview,
  });
}

class ProjectSearchResult {
  final List<ProjectSearchMatch> matches;
  final bool truncated;

  const ProjectSearchResult({required this.matches, this.truncated = false});
}

/// 桌面端项目搜索：优先使用 ripgrep，缺失时回退到 Dart 遍历。
class ProjectSearchService {
  static bool? _ripgrepAvailable;

  static const Set<String> _skipDirs = {
    '.git',
    '.dart_tool',
    '.idea',
    '.gradle',
    'build',
    'node_modules',
    'dist',
    'out',
    'Pods',
    '.venv',
    '__pycache__',
  };

  Future<bool> isRipgrepAvailable() async {
    if (_ripgrepAvailable != null) return _ripgrepAvailable!;
    try {
      final result = await Process.run('rg', ['--version']);
      _ripgrepAvailable = result.exitCode == 0;
    } catch (_) {
      _ripgrepAvailable = false;
    }
    return _ripgrepAvailable!;
  }

  /// 列出项目文件（快速打开用）。
  Future<List<String>> listFiles(String rootPath) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return const [];
    if (await isRipgrepAvailable()) {
      try {
        final result = await Process.run(
          'rg',
          ['--files', '--hidden', '--glob', '!.git/**', rootPath],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (result.exitCode == 0 || result.exitCode == 1) {
          return const LineSplitter()
              .convert(result.stdout as String)
              .where((line) => line.trim().isNotEmpty)
              .toList();
        }
      } catch (_) {
        // 回退到遍历
      }
    }
    final files = <String>[];
    await _walk(root, (entity) async {
      if (entity is File) files.add(entity.path);
    });
    files.sort();
    return files;
  }

  Future<ProjectSearchResult> search(
    String rootPath,
    String query, {
    bool caseSensitive = false,
    bool regex = false,
    int limit = 800,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const ProjectSearchResult(matches: []);
    if (await isRipgrepAvailable()) {
      try {
        return await _searchWithRipgrep(
          rootPath,
          trimmed,
          caseSensitive: caseSensitive,
          regex: regex,
          limit: limit,
        );
      } catch (_) {
        // 回退到 Dart
      }
    }
    return _searchWithDart(
      rootPath,
      trimmed,
      caseSensitive: caseSensitive,
      regex: regex,
      limit: limit,
    );
  }

  Future<ProjectSearchResult> _searchWithRipgrep(
    String rootPath,
    String query, {
    required bool caseSensitive,
    required bool regex,
    required int limit,
  }) async {
    final args = <String>[
      '--json',
      '--line-number',
      '--column',
      '--no-heading',
      '--max-columns',
      '240',
      if (!caseSensitive) '-i',
      if (!regex) '-F',
      '--',
      query,
      rootPath,
    ];
    final result = await Process.run(
      'rg',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw ProcessException('rg', args, '${result.stderr}', result.exitCode);
    }
    final matches = <ProjectSearchMatch>[];
    var truncated = false;
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) continue;
      if (decoded['type'] != 'match') continue;
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) continue;
      final pathText = _rgText(data['path']);
      final lineNumber = data['line_number'];
      final submatches = data['submatches'];
      final preview = _rgText(data['lines']).replaceAll(RegExp(r'\r?\n$'), '');
      final column = submatches is List && submatches.isNotEmpty
          ? ((submatches.first as Map)['start'] as num?)?.toInt() ?? 0
          : 0;
      if (pathText.isEmpty) continue;
      matches.add(
        ProjectSearchMatch(
          path: pathText,
          line: (lineNumber as num?)?.toInt() ?? 1,
          column: column + 1,
          preview: preview.trimRight(),
        ),
      );
      if (matches.length >= limit) {
        truncated = true;
        break;
      }
    }
    return ProjectSearchResult(matches: matches, truncated: truncated);
  }

  String _rgText(Object? value) {
    if (value is Map) {
      final text = value['text'];
      if (text is String) return text;
      final bytes = value['bytes'];
      if (bytes is String) {
        try {
          return utf8.decode(base64Decode(bytes), allowMalformed: true);
        } catch (_) {}
      }
    }
    return '';
  }

  Future<ProjectSearchResult> _searchWithDart(
    String rootPath,
    String query, {
    required bool caseSensitive,
    required bool regex,
    required int limit,
  }) async {
    final pattern = regex
        ? RegExp(query, caseSensitive: caseSensitive)
        : RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
    final matches = <ProjectSearchMatch>[];
    var truncated = false;
    await _walk(Directory(rootPath), (entity) async {
      if (matches.length >= limit) {
        truncated = true;
        return;
      }
      if (entity is! File) return;
      if (!_isTextFile(entity.path)) return;
      try {
        final stat = await entity.stat();
        if (stat.size > 2 * 1024 * 1024) return;
        final content = await entity.readAsString();
        if (content.contains('\u0000')) return;
        final lines = const LineSplitter().convert(content);
        for (var i = 0; i < lines.length; i++) {
          final match = pattern.firstMatch(lines[i]);
          if (match == null) continue;
          matches.add(
            ProjectSearchMatch(
              path: entity.path,
              line: i + 1,
              column: match.start + 1,
              preview: lines[i].trimRight(),
            ),
          );
          if (matches.length >= limit) {
            truncated = true;
            break;
          }
        }
      } catch (_) {
        // 跳过不可读文件
      }
    });
    return ProjectSearchResult(matches: matches, truncated: truncated);
  }

  /// 文件中批量替换；返回替换总次数。
  Future<int> replaceAll(
    String rootPath,
    String query,
    String replacement, {
    bool caseSensitive = false,
    bool regex = false,
  }) async {
    final pattern = regex
        ? RegExp(query, caseSensitive: caseSensitive)
        : RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
    final result = await search(
      rootPath,
      query,
      caseSensitive: caseSensitive,
      regex: regex,
      limit: 5000,
    );
    final paths = result.matches.map((m) => m.path).toSet();
    var count = 0;
    for (final path in paths) {
      try {
        final file = File(path);
        final content = await file.readAsString();
        final replaced = content.replaceAll(pattern, replacement);
        if (replaced != content) {
          count += pattern.allMatches(content).length;
          await file.writeAsString(replaced);
        }
      } catch (_) {
        // 跳过不可写文件
      }
    }
    return count;
  }

  Future<void> _walk(
    Directory directory,
    Future<void> Function(FileSystemEntity entity) onEntity,
  ) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is Directory) {
          if (_skipDirs.contains(p.basename(entity.path))) continue;
          await _walk(entity, onEntity);
        } else {
          await onEntity(entity);
        }
      }
    } catch (_) {
      // 忽略权限问题
    }
  }

  bool _isTextFile(String path) {
    const textExtensions = {
      '.dart',
      '.yaml',
      '.yml',
      '.json',
      '.md',
      '.txt',
      '.xml',
      '.html',
      '.css',
      '.js',
      '.ts',
      '.tsx',
      '.jsx',
      '.kt',
      '.java',
      '.gradle',
      '.swift',
      '.py',
      '.sh',
      '.toml',
      '.ini',
      '.cfg',
      '.env',
    };
    final ext = p.extension(path).toLowerCase();
    return textExtensions.contains(ext) ||
        p.basename(path).startsWith('.env') ||
        p.basename(path) == 'Dockerfile';
  }
}
