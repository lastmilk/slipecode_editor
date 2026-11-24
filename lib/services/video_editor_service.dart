import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 素材类型。
enum VideoAssetKind { image, video, audio, text }

VideoAssetKind videoAssetKindFromName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif'};
  const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'flv'};
  const audios = {'mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'};
  if (images.contains(ext)) return VideoAssetKind.image;
  if (videos.contains(ext)) return VideoAssetKind.video;
  if (audios.contains(ext)) return VideoAssetKind.audio;
  return VideoAssetKind.text;
}

String videoAssetKindLabel(VideoAssetKind kind) => switch (kind) {
      VideoAssetKind.image => '图片',
      VideoAssetKind.video => '视频',
      VideoAssetKind.audio => '音频',
      VideoAssetKind.text => '文本',
    };

String _newId(String prefix) {
  final rnd = Random().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '$prefix-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$rnd';
}

/// 一个素材（本地文件引用）。
@immutable
class VideoAsset {
  const VideoAsset({
    required this.id,
    required this.path,
    required this.name,
    required this.kind,
    this.duration,
  });

  final String id;
  final String path;
  final String name;
  final VideoAssetKind kind;

  /// 视频 / 音频时长（秒），图片与文本为 null。
  final double? duration;

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'kind': kind.name,
        'duration': duration,
      };

  factory VideoAsset.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    return VideoAsset(
      id: (json['id'] ?? _newId('asset')).toString(),
      path: (json['path'] ?? '').toString(),
      name: name,
      kind: VideoAssetKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => videoAssetKindFromName(name),
      ),
      duration: (json['duration'] as num?)?.toDouble(),
    );
  }
}

/// 时间线上的一个片段。
class VideoClip {
  VideoClip({
    required this.id,
    required this.assetId,
    required this.title,
    this.text = '',
    this.inPoint = 0,
    this.duration = 4,
    this.transition = 'none',
    this.volume = 1,
  });

  final String id;

  /// 关联素材 id；文本片段（assetId 为空）使用 [text]。
  final String assetId;

  String title;

  /// 文本片段正文（用于 Remotion / HTML 合成）。
  String text;

  /// 从素材第几秒开始截取。
  double inPoint;

  /// 片段时长（秒）。
  double duration;

  /// 转场：none / fade / slide / zoom。
  String transition;

  /// 音量 0~1。
  double volume;

  Map<String, dynamic> toJson() => {
        'id': id,
        'assetId': assetId,
        'title': title,
        'text': text,
        'inPoint': inPoint,
        'duration': duration,
        'transition': transition,
        'volume': volume,
      };

  factory VideoClip.fromJson(Map<String, dynamic> json) => VideoClip(
        id: (json['id'] ?? _newId('clip')).toString(),
        assetId: (json['assetId'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        text: (json['text'] ?? '').toString(),
        inPoint: (json['inPoint'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 4,
        transition: (json['transition'] ?? 'none').toString(),
        volume: (json['volume'] as num?)?.toDouble() ?? 1,
      );
}

/// 一个 VibeVideo 项目。
class VideoProjectData {
  VideoProjectData({
    required this.id,
    required this.name,
    this.width = 1920,
    this.height = 1080,
    this.fps = 30,
    this.background = '#0A0A0C',
    List<VideoAsset>? assets,
    List<VideoClip>? clips,
    DateTime? updatedAt,
  })  : assets = assets ?? <VideoAsset>[],
        clips = clips ?? <VideoClip>[],
        updatedAt = updatedAt ?? DateTime.now();

  String id;
  String name;
  int width;
  int height;
  double fps;
  String background;
  final List<VideoAsset> assets;
  final List<VideoClip> clips;
  DateTime updatedAt;

  double get totalDuration =>
      clips.fold<double>(0, (sum, clip) => sum + clip.duration);

  VideoAsset? assetOf(String? assetId) {
    if (assetId == null) return null;
    for (final asset in assets) {
      if (asset.id == assetId) return asset;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'width': width,
        'height': height,
        'fps': fps,
        'background': background,
        'assets': assets.map((a) => a.toJson()).toList(),
        'clips': clips.map((c) => c.toJson()).toList(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory VideoProjectData.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'];
    final rawClips = json['clips'];
    return VideoProjectData(
      id: (json['id'] ?? _newId('video')).toString(),
      name: (json['name'] ?? '未命名视频').toString(),
      width: (json['width'] as num?)?.toInt() ?? 1920,
      height: (json['height'] as num?)?.toInt() ?? 1080,
      fps: (json['fps'] as num?)?.toDouble() ?? 30,
      background: (json['background'] ?? '#0A0A0C').toString(),
      assets: rawAssets is List
          ? rawAssets
              .whereType<Map>()
              .map((m) => VideoAsset.fromJson(m.cast<String, dynamic>()))
              .toList()
          : <VideoAsset>[],
      clips: rawClips is List
          ? rawClips
              .whereType<Map>()
              .map((m) => VideoClip.fromJson(m.cast<String, dynamic>()))
              .toList()
          : <VideoClip>[],
      updatedAt:
          DateTime.tryParse((json['updatedAt'] ?? '').toString()) ?? DateTime.now(),
    );
  }
}

/// VibeVideo 编辑器状态服务。
///
/// 同时被工作台 UI 与 AI 工具（MCP）使用：二者读写同一份 [project]，
/// 任何变更都会 [notifyListeners]，UI 实时刷新、AI 无需重读磁盘。
/// 数据落盘到 `<项目根>/.vibevideo/project.json`；没有打开项目时
/// 落到应用支持目录，保证单独体验也能保存。
class VideoEditorService extends ChangeNotifier {
  VideoEditorService._();

  static final VideoEditorService instance = VideoEditorService._();

  static const String _dirName = '.vibevideo';
  static const String _fileName = 'project.json';

  VideoProjectData? _project;
  File? _file;
  String? _root;
  bool _opened = false;

  /// 播放头位置（秒）。
  double _playhead = 0;

  /// 当前选中的片段 id。
  String? _selectedClipId;

  VideoProjectData? get project => _project;
  bool get isOpen => _project != null;
  String? get rootPath => _root;
  String? get projectFile => _file?.path;
  double get playhead => _playhead;
  String? get selectedClipId => _selectedClipId;

  VideoClip? get selectedClip {
    final project = _project;
    if (project == null || _selectedClipId == null) return null;
    for (final clip in project.clips) {
      if (clip.id == _selectedClipId) return clip;
    }
    return null;
  }

  Future<Directory> _baseDir([String? projectPath]) async {
    if (projectPath != null && projectPath.trim().isNotEmpty) {
      return Directory(p.join(projectPath, _dirName));
    }
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'vibevideo'));
  }

  /// 打开（或创建）项目。[projectPath] 为空时使用应用支持目录。
  Future<VideoProjectData> openForProject(String? projectPath,
      {String name = '未命名视频'}) async {
    final dir = await _baseDir(projectPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dir.path, _fileName));
    _root = projectPath;
    _file = file;

    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          _project = VideoProjectData.fromJson(raw.cast<String, dynamic>());
        }
      } catch (e) {
        debugPrint('读取 VibeVideo 项目失败，将新建：$e');
      }
    }
    _project ??= VideoProjectData(
      id: _newId('video'),
      name: name,
    );
    _opened = true;
    _playhead = 0;
    _selectedClipId = _project!.clips.isNotEmpty
        ? _project!.clips.first.id
        : null;
    await save();
    notifyListeners();
    return _project!;
  }

  /// 若尚未打开项目则自动打开（AI 工具调用前使用）。
  Future<VideoProjectData> ensureOpen(String? projectPath) async {
    if (_opened && _project != null) return _project!;
    return openForProject(projectPath);
  }

  Future<void> save() async {
    final project = _project;
    final file = _file;
    if (project == null || file == null) return;
    project.updatedAt = DateTime.now();
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(project.toJson()),
      );
    } catch (e) {
      debugPrint('保存 VibeVideo 项目失败：$e');
    }
  }

  /// 关闭当前项目（切换项目 / 离开工作台时）。
  void close() {
    _project = null;
    _file = null;
    _root = null;
    _opened = false;
    _playhead = 0;
    _selectedClipId = null;
    notifyListeners();
  }

  void setPlayhead(double seconds) {
    final project = _project;
    if (project == null) return;
    _playhead = seconds.clamp(0, project.totalDuration).toDouble();
    notifyListeners();
  }

  void selectClip(String? clipId) {
    _selectedClipId = clipId;
    notifyListeners();
  }

  void renameProject(String name) {
    final project = _project;
    if (project == null) return;
    project.name = name.trim().isEmpty ? project.name : name.trim();
    _touch();
  }

  void setResolution({int? width, int? height}) {
    final project = _project;
    if (project == null) return;
    if (width != null && width > 0) project.width = width;
    if (height != null && height > 0) project.height = height;
    _touch();
  }

  void setFps(double fps) {
    final project = _project;
    if (project == null || fps <= 0) return;
    project.fps = fps;
    _touch();
  }

  void setBackground(String color) {
    final project = _project;
    if (project == null || color.trim().isEmpty) return;
    project.background = color.trim();
    _touch();
  }

  /// 添加素材（同一路径去重）。
  VideoAsset? addAsset(
    String path, {
    String? name,
    double? duration,
  }) {
    final project = _project;
    if (project == null || path.trim().isEmpty) return null;
    final normalized = p.normalize(path);
    for (final asset in project.assets) {
      if (p.normalize(asset.path) == normalized) return asset;
    }
    final asset = VideoAsset(
      id: _newId('asset'),
      path: normalized,
      name: name ?? p.basename(normalized),
      kind: videoAssetKindFromName(normalized),
      duration: duration,
    );
    project.assets.add(asset);
    _touch();
    return asset;
  }

  void removeAsset(String assetId) {
    final project = _project;
    if (project == null) return;
    project.assets.removeWhere((a) => a.id == assetId);
    project.clips.removeWhere((c) => c.assetId == assetId);
    _touch();
  }

  /// 在时间线末尾追加一个片段。
  VideoClip? addClip({
    required String assetId,
    String? title,
    double? duration,
    String? text,
    String transition = 'none',
  }) {
    final project = _project;
    if (project == null) return null;
    final asset = project.assetOf(assetId);
    if (asset == null) return null;
    final clip = VideoClip(
      id: _newId('clip'),
      assetId: assetId,
      title: (title == null || title.trim().isEmpty) ? asset.name : title.trim(),
      text: text ?? '',
      duration: duration ?? asset.duration ?? 4,
      transition: transition,
    );
    project.clips.add(clip);
    _selectedClipId = clip.id;
    _touch();
    return clip;
  }

  /// 追加文本片段（无需素材）。
  VideoClip addTextClip({
    required String text,
    String? title,
    double duration = 4,
    String transition = 'none',
  }) {
    final project = _project!;
    final clip = VideoClip(
      id: _newId('clip'),
      assetId: '',
      title: (title == null || title.trim().isEmpty) ? '文本' : title.trim(),
      text: text,
      duration: duration,
      transition: transition,
    );
    project.clips.add(clip);
    _selectedClipId = clip.id;
    _touch();
    return clip;
  }

  void updateClip(
    String clipId, {
    String? title,
    double? inPoint,
    double? duration,
    String? transition,
    double? volume,
    String? text,
  }) {
    final project = _project;
    if (project == null) return;
    for (final clip in project.clips) {
      if (clip.id != clipId) continue;
      if (title != null && title.trim().isNotEmpty) clip.title = title.trim();
      if (inPoint != null && inPoint >= 0) clip.inPoint = inPoint;
      if (duration != null && duration > 0) clip.duration = duration;
      if (transition != null && transition.trim().isNotEmpty) {
        clip.transition = transition.trim();
      }
      if (volume != null) clip.volume = volume.clamp(0, 1).toDouble();
      if (text != null) clip.text = text;
      break;
    }
    _touch();
  }

  void removeClip(String clipId) {
    final project = _project;
    if (project == null) return;
    project.clips.removeWhere((c) => c.id == clipId);
    if (_selectedClipId == clipId) {
      _selectedClipId = project.clips.isNotEmpty ? project.clips.first.id : null;
    }
    _touch();
  }

  /// 移动片段到新的索引位置。
  bool moveClip(int from, int to) {
    final project = _project;
    if (project == null) return false;
    if (from < 0 || from >= project.clips.length) return false;
    final target = to.clamp(0, project.clips.length - 1);
    if (from == target) return false;
    final clip = project.clips.removeAt(from);
    project.clips.insert(target, clip);
    _touch();
    return true;
  }

  /// 按顺序重排片段 id；缺失的保持原相对位置追加在末尾。
  void reorderClips(List<String> orderedIds) {
    final project = _project;
    if (project == null) return;
    final byId = {for (final c in project.clips) c.id: c};
    final result = <VideoClip>[];
    for (final id in orderedIds) {
      final clip = byId.remove(id);
      if (clip != null) result.add(clip);
    }
    result.addAll(byId.values);
    project.clips
      ..clear()
      ..addAll(result);
    _touch();
  }

  /// 用完整 JSON 覆盖项目（AI 导入结构化编排时使用）。
  void replaceFromJson(Map<String, dynamic> json) {
    final next = VideoProjectData.fromJson(json);
    final current = _project;
    if (current != null) {
      next.id = current.id;
      if (next.name.trim().isEmpty) next.name = current.name;
    }
    _project = next;
    _selectedClipId = next.clips.isNotEmpty ? next.clips.first.id : null;
    _touch();
  }

  /// 按时间点找到对应片段及其内部进度（用于预览）。
  ({VideoClip clip, double localSeconds})? clipAt(double seconds) {
    final project = _project;
    if (project == null) return null;
    var cursor = 0.0;
    for (final clip in project.clips) {
      if (seconds < cursor + clip.duration || clip == project.clips.last) {
        return (clip: clip, localSeconds: (seconds - cursor).clamp(0, clip.duration));
      }
      cursor += clip.duration;
    }
    return null;
  }

  void _touch() {
    unawaited(save());
    notifyListeners();
  }
}
