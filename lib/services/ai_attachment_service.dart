import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'account_service.dart';
import 'llm_service.dart' show ChatImageAttachment;

/// AI 附件上传限制（服务端管理端可配置）
class AiAttachmentLimits {
  final bool enabled;
  final int maxFiles;
  final int maxFileMb;
  final int maxTotalMb;
  final int maxUnzipFiles;
  final int maxUnzipMb;

  const AiAttachmentLimits({
    this.enabled = true,
    this.maxFiles = 5,
    this.maxFileMb = 10,
    this.maxTotalMb = 30,
    this.maxUnzipFiles = 50,
    this.maxUnzipMb = 50,
  });

  factory AiAttachmentLimits.fromJson(Map<String, dynamic> json) {
    int read(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;
    return AiAttachmentLimits(
      enabled: json['enabled'] != false,
      maxFiles: read('maxFiles', 5),
      maxFileMb: read('maxFileMb', 10),
      maxTotalMb: read('maxTotalMb', 30),
      maxUnzipFiles: read('maxUnzipFiles', 50),
      maxUnzipMb: read('maxUnzipMb', 50),
    );
  }
}

/// 一个已读取的文本附件
class AiTextAttachment {
  final String name;
  final String content;
  final int size;
  final bool truncated;

  const AiTextAttachment({
    required this.name,
    required this.content,
    this.size = 0,
    this.truncated = false,
  });
}

/// 附件选择结果
class AiAttachmentPickResult {
  final List<ChatImageAttachment> images;
  final List<AiTextAttachment> files;
  final List<String> skipped;

  const AiAttachmentPickResult({
    this.images = const [],
    this.files = const [],
    this.skipped = const [],
  });

  bool get isEmpty => images.isEmpty && files.isEmpty;
}

/// AI 附件选择与读取
///
/// - 图片：读取为 data URL，随消息以多模态 content 数组发送
/// - 文本文件：读取内容后拼进提示词
/// - Zip：优先上传服务端解压到临时目录（云解压），未登录时本地解压兜底
class AiAttachmentService {
  AiAttachmentService._();

  static final AiAttachmentService instance = AiAttachmentService._();

  AiAttachmentLimits _limits = const AiAttachmentLimits();
  bool _limitsLoaded = false;

  AiAttachmentLimits get limits => _limits;

  static const _textExtensions = {
    '.txt', '.md', '.markdown', '.json', '.js', '.mjs', '.cjs', '.ts', '.tsx',
    '.jsx', '.dart', '.kt', '.java', '.py', '.go', '.rs', '.c', '.h', '.cpp',
    '.hpp', '.cs', '.php', '.rb', '.swift', '.m', '.mm', '.html', '.htm',
    '.css', '.scss', '.less', '.xml', '.yml', '.yaml', '.toml', '.ini', '.cfg',
    '.conf', '.env', '.sh', '.bash', '.zsh', '.bat', '.ps1', '.sql', '.gradle',
    '.properties', '.csv', '.tsv', '.log', '.vue', '.svelte', '.lua', '.r',
    '.scala', '.pl', '.tex', '.proto', '.graphql',
  };

  static const _maxPreviewBytes = 64 * 1024;

  /// 从服务端刷新限制（登录后调用，失败时保留默认值）
  Future<void> ensureLimits({String? token}) async {
    if (_limitsLoaded || token == null || token.isEmpty) return;
    try {
      final data = await AccountService.instance.fetchAiLimits(token);
      _limits = AiAttachmentLimits.fromJson(data);
      _limitsLoaded = true;
    } catch (e) {
      debugPrint('获取 AI 附件限制失败：$e');
    }
  }

  bool _isTextFile(String name) {
    final ext = p.extension(name).toLowerCase();
    if (_textExtensions.contains(ext)) return true;
    final base = p.basename(name).toLowerCase();
    return const {'dockerfile', 'makefile', 'readme', 'license', 'gemfile'}
        .contains(base);
  }

  /// 选择图片（可多选）
  Future<AiAttachmentPickResult> pickImages() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) {
      return const AiAttachmentPickResult();
    }
    final images = <ChatImageAttachment>[];
    final skipped = <String>[];
    var total = 0;
    final maxBytes = _limits.maxFileMb * 1024 * 1024;
    final maxTotal = _limits.maxTotalMb * 1024 * 1024;
    for (final file in result.files.take(_limits.maxFiles)) {
      try {
        final bytes = await _readBytes(file);
        if (bytes == null) {
          skipped.add('${file.name}（无法读取）');
          continue;
        }
        if (bytes.length > maxBytes) {
          skipped.add('${file.name}（超过 ${_limits.maxFileMb}MB）');
          continue;
        }
        total += bytes.length;
        if (total > maxTotal) {
          skipped.add('${file.name}（超过总大小限制）');
          continue;
        }
        final mime = _mimeOf(file.name);
        images.add(
          ChatImageAttachment(
            name: file.name,
            dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
          ),
        );
      } catch (e) {
        skipped.add('${file.name}（$e）');
      }
    }
    return AiAttachmentPickResult(images: images, skipped: skipped);
  }

  /// 选择文件（文本直接读取；Zip 云解压或本地解压）
  Future<AiAttachmentPickResult> pickFiles({String? token}) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) {
      return const AiAttachmentPickResult();
    }
    final files = <AiTextAttachment>[];
    final skipped = <String>[];
    var totalChars = 0;
    const maxTotalChars = 400 * 1024;
    for (final file in result.files.take(_limits.maxFiles)) {
      try {
        if (p.extension(file.name).toLowerCase() == '.zip') {
          final zipResult = await _handleZip(file, token);
          files.addAll(zipResult.files);
          skipped.addAll(zipResult.skipped);
          continue;
        }
        if (!_isTextFile(file.name)) {
          skipped.add('${file.name}（暂不支持解析该类型）');
          continue;
        }
        final bytes = await _readBytes(file);
        if (bytes == null) {
          skipped.add('${file.name}（无法读取）');
          continue;
        }
        if (bytes.length > _limits.maxFileMb * 1024 * 1024) {
          skipped.add('${file.name}（超过 ${_limits.maxFileMb}MB）');
          continue;
        }
        final limit = bytes.length > _maxPreviewBytes
            ? _maxPreviewBytes
            : bytes.length;
        final text = utf8.decode(bytes.sublist(0, limit), allowMalformed: true);
        if (totalChars + text.length > maxTotalChars) {
          skipped.add('${file.name}（超过总内容限制）');
          continue;
        }
        totalChars += text.length;
        files.add(
          AiTextAttachment(
            name: file.name,
            content: text,
            size: bytes.length,
            truncated: limit < bytes.length,
          ),
        );
      } catch (e) {
        skipped.add('${file.name}（$e）');
      }
    }
    return AiAttachmentPickResult(files: files, skipped: skipped);
  }

  /// 处理 Zip：优先服务端云解压，失败或未登录时本地解压
  Future<AiAttachmentPickResult> _handleZip(
    PlatformFile file,
    String? token,
  ) async {
    final bytes = await _readBytes(file);
    if (bytes == null) {
      return const AiAttachmentPickResult(skipped: ['无法读取 Zip 文件']);
    }
    if (bytes.length > _limits.maxFileMb * 1024 * 1024) {
      return AiAttachmentPickResult(
        skipped: ['${file.name}（超过 ${_limits.maxFileMb}MB）'],
      );
    }
    if (token != null && token.isNotEmpty && AccountService.instance.isConfigured) {
      try {
        final data = await AccountService.instance.unzipAiFiles(
          token,
          name: file.name,
          dataBase64: base64Encode(bytes),
        );
        final raw = data['files'];
        final files = <AiTextAttachment>[];
        final skipped = <String>[];
        if (raw is List) {
          for (final item in raw) {
            if (item is! Map) continue;
            final name = (item['path'] ?? '').toString();
            final text = (item['text'] ?? '').toString();
            if (text.isEmpty) {
              skipped.add('$name（非文本文件）');
              continue;
            }
            files.add(
              AiTextAttachment(
                name: name,
                content: text,
                size: (item['size'] as num?)?.toInt() ?? text.length,
                truncated: item['truncated'] == true,
              ),
            );
          }
        }
        return AiAttachmentPickResult(files: files, skipped: skipped);
      } catch (e) {
        debugPrint('云端解压失败，改本地解压：$e');
      }
    }
    return _unzipLocally(file.name, bytes);
  }

  /// 本地解压（archive 包），仅提取文本文件
  AiAttachmentPickResult _unzipLocally(String name, Uint8List bytes) {
    final files = <AiTextAttachment>[];
    final skipped = <String>[];
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      var count = 0;
      var total = 0;
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        count += 1;
        if (count > _limits.maxUnzipFiles) {
          skipped.add('文件数超过上限（${_limits.maxUnzipFiles}）');
          break;
        }
        final path = entry.name.replaceAll('\\', '/');
        if (path.startsWith('/') || path.split('/').contains('..')) {
          skipped.add('$path（非法路径）');
          continue;
        }
        total += entry.size;
        if (total > _limits.maxUnzipMb * 1024 * 1024) {
          skipped.add('解压总大小超过上限（${_limits.maxUnzipMb}MB）');
          break;
        }
        if (!_isTextFile(path)) {
          skipped.add('$path（非文本文件）');
          continue;
        }
        final content = entry.content;
        if (content is! List<int>) continue;
        final limit = content.length > _maxPreviewBytes
            ? _maxPreviewBytes
            : content.length;
        files.add(
          AiTextAttachment(
            name: path,
            content: utf8.decode(
              content.sublist(0, limit),
              allowMalformed: true,
            ),
            size: content.length,
            truncated: limit < content.length,
          ),
        );
      }
    } catch (e) {
      skipped.add('$name（解压失败：$e）');
    }
    return AiAttachmentPickResult(files: files, skipped: skipped);
  }

  Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    if (file.path == null) return null;
    return File(file.path!).readAsBytes();
  }

  static String _mimeOf(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  /// 把文本附件拼成提示词，附带在用户消息之后
  static String composeContext(List<AiTextAttachment> files) {
    if (files.isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln()
      ..writeln()
      ..writeln('以下是用户随消息上传的文件内容（可能被截断）：');
    for (final file in files) {
      buffer
        ..writeln()
        ..writeln('### ${file.name}（${file.size} bytes${file.truncated ? '，已截断' : ''}）')
        ..writeln('```')
        ..writeln(file.content)
        ..writeln('```');
    }
    return buffer.toString();
  }
}
