import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'toolchain_models.dart';

/// 版本清单拉取（带 24h 本地缓存）。
///
/// 网络失败时退回内置的已知稳定版本，保证「离线也能看到可安装项」，
/// 但此时下载大概率仍会失败，界面会给出提示。
class ToolchainCatalogService {
  static const _cacheTtl = Duration(hours: 24);

  static const _flutterOfficial =
      'https://storage.googleapis.com/flutter_infra_release/releases';
  static const _flutterMirror =
      'https://storage.flutter-io.cn/flutter_infra_release/releases';

  static const _dartOfficial =
      'https://storage.googleapis.com/dart-archive/channels/stable/release';
  static const _dartMirror =
      'https://storage.flutter-io.cn/dart-archive/channels/stable/release';

  static const _nodeOfficial = 'https://nodejs.org/dist';
  static const _nodeMirror = 'https://npmmirror.com/mirrors/node';

  static const _javaApi = 'https://api.adoptium.net/v3';

  /// Python 预编译发行版（python-build-standalone）
  static const _pythonApi =
      'https://api.github.com/repos/astral-sh/python-build-standalone';

  Directory? _cacheDir;

  Future<Directory> _cache() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}toolchains'
      '${Platform.pathSeparator}cache',
    );
    await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// 拉取可安装版本列表。
  ///
  /// [useMirror] 为 true 时优先国内镜像；镜像失败自动回退官方源。
  Future<List<ToolchainRelease>> releases(
    ToolchainKind kind, {
    required bool useMirror,
    bool forceRefresh = false,
  }) async {
    final cacheFile = File(
      '${(await _cache()).path}${Platform.pathSeparator}'
      '${kind.id}_${useMirror ? 'cn' : 'official'}.json',
    );
    if (!forceRefresh && await cacheFile.exists()) {
      try {
        final raw = jsonDecode(await cacheFile.readAsString());
        if (raw is Map<String, dynamic>) {
          final fetchedAt = (raw['fetchedAt'] as num?)?.toInt() ?? 0;
          final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
          if (age >= 0 && age < _cacheTtl.inMilliseconds) {
            final list = _decodeReleases(kind, raw['releases']);
            if (list.isNotEmpty) return list;
          }
        }
      } catch (e) {
        debugPrint('读取工具链清单缓存失败：$e');
      }
    }

    final sources = useMirror
        ? [_sourceFor(kind, mirror: true), _sourceFor(kind, mirror: false)]
        : [_sourceFor(kind, mirror: false)];
    for (final source in sources) {
      try {
        final list = await _fetch(kind, source);
        if (list.isNotEmpty) {
          unawaited(_writeCache(cacheFile, list));
          return list;
        }
      } catch (e) {
        debugPrint('拉取 ${kind.id} 版本清单失败（$source）：$e');
      }
    }
    return _fallbackReleases(kind);
  }

  String _sourceFor(ToolchainKind kind, {required bool mirror}) =>
      switch (kind) {
        ToolchainKind.flutter => mirror ? _flutterMirror : _flutterOfficial,
        ToolchainKind.dart => mirror ? _dartMirror : _dartOfficial,
        ToolchainKind.node => mirror ? _nodeMirror : _nodeOfficial,
        ToolchainKind.java => _javaApi,
        ToolchainKind.python => _pythonApi,
      };

  Future<void> _writeCache(File file, List<ToolchainRelease> releases) async {
    try {
      await file.writeAsString(
        jsonEncode({
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
          'releases': releases
              .map((r) => {
                    'version': r.version,
                    'url': r.url,
                    'size': r.sizeBytes,
                    'sha256': r.sha256,
                    'lts': r.lts,
                  })
              .toList(),
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('写入工具链清单缓存失败：$e');
    }
  }

  List<ToolchainRelease> _decodeReleases(ToolchainKind kind, Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final map = item.cast<String, dynamic>();
          final version = (map['version'] as String?) ?? '';
          final url = (map['url'] as String?) ?? '';
          if (version.isEmpty || url.isEmpty) return null;
          return ToolchainRelease(
            kind: kind,
            version: version,
            url: url,
            sizeBytes: (map['size'] as num?)?.toInt(),
            sha256: map['sha256'] as String?,
            lts: map['lts'] == true,
          );
        })
        .whereType<ToolchainRelease>()
        .toList();
  }

  Future<List<ToolchainRelease>> _fetch(
    ToolchainKind kind,
    String source,
  ) async {
    switch (kind) {
      case ToolchainKind.flutter:
        final raw = await _getText('$source/releases_${_flutterOs()}.json');
        return _parseFlutter(raw, source);
      case ToolchainKind.dart:
        return _fetchDart(source);
      case ToolchainKind.node:
        final raw = await _getText('$source/index.json');
        return _parseNode(raw, source);
      case ToolchainKind.java:
        return _fetchJava(source);
      case ToolchainKind.python:
        return _fetchPython(source);
    }
  }

  String _flutterOs() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  /// Flutter 官方清单：base_url + archive（相对路径），带 sha256。
  List<ToolchainRelease> _parseFlutter(String text, String source) {
    final data = jsonDecode(text);
    if (data is! Map) return const [];
    final releases = data['releases'];
    if (releases is! List) return const [];
    final os = _flutterOs();
    final arch = hostArchitecture;
    final result = <ToolchainRelease>[];
    for (final item in releases) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      if (map['channel'] != 'stable') continue;
      final archive = (map['archive'] as String?) ?? '';
      if (!archive.contains('_$os')) continue;
      // 有 arm64 归档时优先匹配宿主架构，避免 x64 归档在 arm 上跑不动
      if (arch == 'arm64' && !archive.contains('arm64')) continue;
      if (arch == 'x64' && archive.contains('arm64')) continue;
      final version = (map['version'] as String?) ?? '';
      if (version.isEmpty) continue;
      result.add(ToolchainRelease(
        kind: ToolchainKind.flutter,
        version: version,
        url: '$source/$archive',
        sha256: map['sha256'] as String?,
        sizeBytes: null,
      ));
    }
    result.sort((a, b) => compareVersions(b.version, a.version));
    return result.take(15).toList();
  }

  /// Dart 归档只提供 latest 的 VERSION，因此再补两个已知稳定版本。
  Future<List<ToolchainRelease>> _fetchDart(String source) async {
    final raw = await _getText('$source/latest/VERSION');
    final version = (jsonDecode(raw) as Map)['version'] as String?;
    final result = <ToolchainRelease>[];
    if (version != null && version.isNotEmpty) {
      result.add(_dartRelease(source, version));
    }
    for (final known in const ['3.5.4', '3.4.4']) {
      if (known != version) result.add(_dartRelease(source, known));
    }
    return result;
  }

  ToolchainRelease _dartRelease(String source, String version) {
    final arch = hostArchitecture == 'arm64' ? 'arm64' : 'x64';
    final String file;
    if (Platform.isWindows) {
      file = 'dartsdk-windows-$arch-release.zip';
    } else if (Platform.isMacOS) {
      file = 'dartsdk-macos-$arch-release.zip';
    } else {
      file = 'dartsdk-linux-$arch-release.tar.xz';
    }
    return ToolchainRelease(
      kind: ToolchainKind.dart,
      version: version,
      url: '$source/$version/sdk/$file',
    );
  }

  List<ToolchainRelease> _parseNode(String text, String source) {
    final data = jsonDecode(text);
    if (data is! List) return const [];
    final os = Platform.isWindows
        ? 'win'
        : Platform.isMacOS
            ? 'darwin'
            : 'linux';
    final arch = hostArchitecture == 'arm64' ? 'arm64' : 'x64';
    final extension = Platform.isWindows
        ? 'zip'
        : Platform.isMacOS
            ? 'tar.gz'
            : 'tar.xz';
    // index.json 的 files 标识：linux-x64 / osx-arm64-tar / win-x64-zip
    final fileKey = Platform.isWindows
        ? 'win-$arch-zip'
        : Platform.isMacOS
            ? 'osx-$arch-tar'
            : 'linux-$arch';
    final result = <ToolchainRelease>[];
    for (final item in data) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final version = (map['version'] as String?) ?? '';
      if (version.isEmpty) continue;
      final files = map['files'];
      if (files is List && !files.contains(fileKey)) continue;
      final lts = map['lts'];
      result.add(ToolchainRelease(
        kind: ToolchainKind.node,
        version: version,
        url: '$source/$version/node-$version-$os-$arch.$extension',
        lts: lts != null && lts != false,
      ));
    }
    // LTS 优先，其次按版本倒序
    result.sort((a, b) {
      if (a.lts != b.lts) return a.lts ? -1 : 1;
      return compareVersions(b.version, a.version);
    });
    return result.take(12).toList();
  }

  Future<List<ToolchainRelease>> _fetchJava(String source) async {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'mac'
            : 'linux';
    final arch = hostArchitecture == 'arm64' ? 'aarch64' : 'x64';
    final raw = await _getText(
      '$_javaApi/info/release_names'
      '?architecture=$arch&image_type=jdk&os=$os&page_size=8'
      '&release_type=ga&sort_order=DESC&vendor=eclipse',
    );
    final data = jsonDecode(raw);
    if (data is! Map) return const [];
    final names = data['releases'];
    if (names is! List) return const [];
    return names
        .whereType<String>()
        .map((version) => ToolchainRelease(
              kind: ToolchainKind.java,
              version: version,
              url: '$_javaApi/binary/version/'
                  '${Uri.encodeComponent(version)}/$os/$arch/jdk/hotspot/'
                  'normal/eclipse?project=jdk',
              lts: version.startsWith('jdk-21') || version.startsWith('jdk-17'),
            ))
        .toList();
  }

  /// python-build-standalone 的 GitHub Release：从资产名解析版本
  /// （cpython-3.12.7+20241105-x86_64-unknown-linux-gnu-install_only.tar.gz）
  Future<List<ToolchainRelease>> _fetchPython(String source) async {
    final target = _pythonTarget();
    final raw = await _getText('$source/releases?per_page=3');
    final data = jsonDecode(raw);
    if (data is! List) return const [];
    final versionPattern = RegExp(r'^cpython-(\d+\.\d+\.\d+)\+');
    final result = <ToolchainRelease>[];
    for (final item in data) {
      if (item is! Map) continue;
      final assets = item['assets'];
      if (assets is! List) continue;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = (asset['name'] as String?) ?? '';
        if (!name.contains(target) || !name.endsWith('-install_only.tar.gz')) {
          continue;
        }
        final match = versionPattern.firstMatch(name);
        final url = asset['browser_download_url'] as String?;
        if (match == null || url == null || url.isEmpty) continue;
        result.add(ToolchainRelease(
          kind: ToolchainKind.python,
          version: match.group(1)!,
          url: url,
          sizeBytes: (asset['size'] as num?)?.toInt(),
        ));
      }
    }
    result.sort((a, b) => compareVersions(b.version, a.version));
    return result;
  }

  /// python-build-standalone 的平台三元组
  String _pythonTarget() {
    final arm = hostArchitecture == 'arm64';
    if (Platform.isWindows) {
      return arm ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc';
    }
    if (Platform.isMacOS) {
      return arm ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin';
    }
    return arm ? 'aarch64-unknown-linux-gnu' : 'x86_64-unknown-linux-gnu';
  }

  /// 网络不可用时的内置稳定版本（仅保证格式正确）。
  List<ToolchainRelease> _fallbackReleases(ToolchainKind kind) {
    final os = _flutterOs();
    switch (kind) {
      case ToolchainKind.flutter:
        return [
          ToolchainRelease(
            kind: kind,
            version: '3.24.5',
            url: '$_flutterOfficial/stable/$os/'
                'flutter_${os}_3.24.5-stable.tar.xz',
          ),
          ToolchainRelease(
            kind: kind,
            version: '3.22.3',
            url: '$_flutterOfficial/stable/$os/'
                'flutter_${os}_3.22.3-stable.tar.xz',
          ),
        ];
      case ToolchainKind.dart:
        return [
          ToolchainRelease(
            kind: ToolchainKind.dart,
            version: '3.5.4',
            url: '$_dartOfficial/3.5.4/sdk/'
                'dartsdk-${Platform.isWindows ? 'windows' : 'linux'}-x64-'
                'release.${Platform.isWindows ? 'zip' : 'tar.xz'}',
          ),
        ];
      case ToolchainKind.node:
        final extension = Platform.isWindows ? 'zip' : 'tar.xz';
        final nodeOs = Platform.isWindows ? 'win' : 'linux';
        return [
          ToolchainRelease(
            kind: kind,
            version: 'v20.18.0',
            url: '$_nodeOfficial/v20.18.0/'
                'node-v20.18.0-$nodeOs-x64.$extension',
            lts: true,
          ),
        ];
      case ToolchainKind.java:
        return const [];
      case ToolchainKind.python:
        return const [];
    }
  }

  Future<String> _getText(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'SLIPE-Editor/1.0');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
}
