import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'backend_http.dart';

/// 教程资源包
class TutorialAsset {
  final String id;
  final String name;
  final int size;
  final String url;

  const TutorialAsset({
    required this.id,
    required this.name,
    this.size = 0,
    this.url = '',
  });

  factory TutorialAsset.fromJson(Map<String, dynamic> json) => TutorialAsset(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '资源包').toString(),
        size: (json['size'] as num?)?.toInt() ?? 0,
        url: (json['url'] ?? '').toString(),
      );
}

/// 课程摘要（清单中的一项）
class TutorialLessonMeta {
  final String id;
  final String title;
  final String summary;
  final int order;
  final int durationMin;
  final int stepCount;
  final List<String> tags;
  final List<TutorialAsset> assets;

  const TutorialLessonMeta({
    required this.id,
    required this.title,
    this.summary = '',
    this.order = 0,
    this.durationMin = 0,
    this.stepCount = 0,
    this.tags = const [],
    this.assets = const [],
  });

  factory TutorialLessonMeta.fromJson(Map<String, dynamic> json) =>
      TutorialLessonMeta(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        order: (json['order'] as num?)?.toInt() ?? 0,
        durationMin: (json['durationMin'] as num?)?.toInt() ?? 0,
        stepCount: (json['stepCount'] as num?)?.toInt() ?? 0,
        tags: ((json['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        assets: ((json['assets'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TutorialAsset.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 课程轨道
class TutorialTrack {
  final String id;
  final String name;
  final String description;
  final List<TutorialLessonMeta> lessons;

  const TutorialTrack({
    required this.id,
    required this.name,
    this.description = '',
    this.lessons = const [],
  });

  factory TutorialTrack.fromJson(Map<String, dynamic> json) => TutorialTrack(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        lessons: ((json['lessons'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TutorialLessonMeta.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 教程清单
class TutorialManifest {
  final int version;
  final List<TutorialTrack> tracks;

  const TutorialManifest({this.version = 1, this.tracks = const []});

  int get totalLessons =>
      tracks.fold<int>(0, (sum, track) => sum + track.lessons.length);

  factory TutorialManifest.fromJson(Map<String, dynamic> json) =>
      TutorialManifest(
        version: (json['version'] as num?)?.toInt() ?? 1,
        tracks: ((json['tracks'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TutorialTrack.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 课程步骤
class TutorialStep {
  final String type; // text | code | quiz | action
  final String title;
  final String body;
  final String language;
  final String code;
  final String question;
  final List<String> options;
  final int answer;
  final String explain;

  const TutorialStep({
    required this.type,
    this.title = '',
    this.body = '',
    this.language = 'dart',
    this.code = '',
    this.question = '',
    this.options = const [],
    this.answer = 0,
    this.explain = '',
  });

  factory TutorialStep.fromJson(Map<String, dynamic> json) => TutorialStep(
        type: (json['type'] ?? 'text').toString(),
        title: (json['title'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
        language: (json['language'] ?? 'dart').toString(),
        code: (json['code'] ?? '').toString(),
        question: (json['question'] ?? '').toString(),
        options: ((json['options'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        answer: (json['answer'] as num?)?.toInt() ?? 0,
        explain: (json['explain'] ?? '').toString(),
      );
}

/// 完整课程
class TutorialLesson {
  final String id;
  final String track;
  final String title;
  final String summary;
  final List<TutorialStep> steps;
  final List<TutorialAsset> assets;

  const TutorialLesson({
    required this.id,
    required this.track,
    required this.title,
    this.summary = '',
    this.steps = const [],
    this.assets = const [],
  });

  factory TutorialLesson.fromJson(Map<String, dynamic> json) => TutorialLesson(
        id: (json['id'] ?? '').toString(),
        track: (json['track'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        steps: ((json['steps'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TutorialStep.fromJson(e.cast<String, dynamic>()))
            .toList(),
        assets: ((json['assets'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TutorialAsset.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// 社区教程服务：清单 / 单课 / 资源按需下载 / 学习进度
class TutorialService {
  TutorialService._();

  static final TutorialService instance = TutorialService._();

  final http.Client _client = BackendHttp.client;
  final Map<String, TutorialLesson> _lessonCache = {};
  TutorialManifest? _manifest;
  static const _progressKey = 'slipe_tutorial_progress';

  bool get isConfigured => AppConfig.isAccountBackendConfigured;

  Uri _u(String path) => Uri.parse('${AppConfig.accountBackendBase}$path');

  Future<Directory> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'tutorials'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<TutorialManifest> fetchManifest({bool force = false}) async {
    if (!force && _manifest != null) return _manifest!;
    try {
      final res = await _client
          .get(_u('/api/tutorials'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('获取教程列表失败（HTTP ${res.statusCode}）');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final manifest = TutorialManifest.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : const {},
      );
      _manifest = manifest;
      final dir = await _rootDir();
      await File(p.join(dir.path, 'manifest.json')).writeAsString(
        jsonEncode(data),
      );
      return manifest;
    } catch (e) {
      // 网络不可用时回退到本地缓存
      if (_manifest != null) return _manifest!;
      try {
        final dir = await _rootDir();
        final file = File(p.join(dir.path, 'manifest.json'));
        if (await file.exists()) {
          final data = jsonDecode(await file.readAsString());
          final manifest = TutorialManifest.fromJson(
            data is Map ? Map<String, dynamic>.from(data) : const {},
          );
          _manifest = manifest;
          return manifest;
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<TutorialLesson> fetchLesson(String id) async {
    final cached = _lessonCache[id];
    if (cached != null) return cached;
    try {
      final res = await _client
          .get(_u('/api/tutorials/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('获取课程失败（HTTP ${res.statusCode}）');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final lesson = TutorialLesson.fromJson(
        data is Map ? Map<String, dynamic>.from(data) : const {},
      );
      _lessonCache[id] = lesson;
      final dir = await _rootDir();
      final lessonDir = Directory(p.join(dir.path, id));
      if (!await lessonDir.exists()) await lessonDir.create(recursive: true);
      await File(p.join(lessonDir.path, 'lesson.json')).writeAsString(
        jsonEncode(data),
      );
      return lesson;
    } catch (e) {
      try {
        final dir = await _rootDir();
        final file = File(p.join(dir.path, id, 'lesson.json'));
        if (await file.exists()) {
          final data = jsonDecode(await file.readAsString());
          final lesson = TutorialLesson.fromJson(
            data is Map ? Map<String, dynamic>.from(data) : const {},
          );
          _lessonCache[id] = lesson;
          return lesson;
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<String> assetDir(String lessonId, String assetId) async {
    final root = await _rootDir();
    return p.join(root.path, lessonId, 'assets', assetId);
  }

  Future<bool> isAssetDownloaded(String lessonId, String assetId) async {
    final dir = Directory(await assetDir(lessonId, assetId));
    if (!await dir.exists()) return false;
    final entries = await dir.list().toList();
    return entries.isNotEmpty;
  }

  String assetUrl(TutorialAsset asset) {
    final url = asset.url.trim();
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.isEmpty) return '';
    return '${AppConfig.accountBackendBase}$url';
  }

  /// 下载并解压课程资源包
  Future<String> downloadAsset(
    String lessonId,
    TutorialAsset asset, {
    void Function(double progress)? onProgress,
  }) async {
    final url = assetUrl(asset);
    if (url.isEmpty) throw Exception('资源地址为空');
    final root = await _rootDir();
    final zipPath = p.join(root.path, lessonId, '${asset.id}.zip');
    final zipFile = File(zipPath);
    if (!await zipFile.parent.exists()) {
      await zipFile.parent.create(recursive: true);
    }

    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('下载失败（HTTP ${response.statusCode}）');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = zipFile.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      }
    } finally {
      await sink.close();
    }
    onProgress?.call(1);

    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final target = await assetDir(lessonId, asset.id);
    final targetDir = Directory(target);
    if (await targetDir.exists()) await targetDir.delete(recursive: true);
    await targetDir.create(recursive: true);

    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (name.split('/').contains('..')) continue;
      final outPath = p.join(target, name);
      final outFile = File(outPath);
      if (!await outFile.parent.exists()) {
        await outFile.parent.create(recursive: true);
      }
      await outFile.writeAsBytes(file.content as List<int>);
    }
    return target;
  }

  // -------------------------------------------------------------------------
  // 学习进度
  // -------------------------------------------------------------------------

  Future<Map<String, int>> loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_progressKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry('$key', (value as num?)?.toInt() ?? 0),
        );
      }
    } catch (e) {
      debugPrint('教程进度读取失败：$e');
    }
    return {};
  }

  Future<int> progressFor(String lessonId) async {
    final all = await loadProgress();
    return all[lessonId] ?? 0;
  }

  Future<void> saveProgress(String lessonId, int stepIndex, int totalSteps) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadProgress();
    all[lessonId] = stepIndex.clamp(0, totalSteps);
    await prefs.setString(_progressKey, jsonEncode(all));
  }
}
