import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 本地静态预览服务（HTML / Web 产物）。
///
/// 仅监听 127.0.0.1，首次启动自动寻找可用端口。
class LocalPreviewService {
  LocalPreviewService._();

  static final LocalPreviewService instance = LocalPreviewService._();

  HttpServer? _server;
  String? _root;

  bool get isRunning => _server != null;

  String? get root => _root;

  Uri? get uri {
    final server = _server;
    if (server == null) return null;
    return Uri.parse('http://127.0.0.1:${server.port}/');
  }

  Future<Uri> serve(String rootPath) async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      throw StateError('目录不存在：$rootPath');
    }
    final absoluteRoot = p.normalize(root.absolute.path);
    if (_server != null && _root == absoluteRoot) return uri!;
    await stop();
    _root = absoluteRoot;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object e) => debugPrint('预览服务错误：$e'));
    final address = uri!;
    debugPrint('本地预览已启动：$address（$absoluteRoot）');
    return address;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _root = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final root = _root;
    if (root == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final response = request.response;
    try {
      var relative = Uri.decodeComponent(request.uri.path);
      if (relative.isEmpty || relative == '/') relative = '/index.html';
      if (relative.endsWith('/')) relative = '${relative}index.html';
      // p.join 遇到绝对路径会丢弃前缀，先去掉前导分隔符
      final safeRelative =
          relative.startsWith('/') ? relative.substring(1) : relative;
      final requested = p.normalize(p.join(root, safeRelative));
      // 防目录穿越
      if (!p.isWithin(root, requested) && requested != root) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      var target = File(requested);
      if (!await target.exists()) {
        final directory = Directory(requested);
        if (await directory.exists()) {
          target = File(p.join(requested, 'index.html'));
        }
      }
      if (!await target.exists()) {
        // SPA 回退到 index.html
        final fallback = File(p.join(root, 'index.html'));
        if (await fallback.exists()) {
          await _writeFile(response, fallback);
          return;
        }
        response.statusCode = HttpStatus.notFound;
        response.write('404 Not Found: $relative');
        await response.close();
        return;
      }
      await _writeFile(response, target);
    } catch (e) {
      debugPrint('预览请求失败：$e');
      response.statusCode = HttpStatus.internalServerError;
      try {
        await response.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  Future<void> _writeFile(HttpResponse response, File file) async {
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentType(file.path),
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await response.addStream(file.openRead());
    await response.close();
  }

  String _contentType(String path) {
    final extension = p.extension(path).toLowerCase();
    return switch (extension) {
      '.html' || '.htm' => 'text/html; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.js' || '.mjs' => 'application/javascript; charset=utf-8',
      '.json' => 'application/json; charset=utf-8',
      '.wasm' => 'application/wasm',
      '.svg' => 'image/svg+xml',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.ico' => 'image/x-icon',
      '.woff' => 'font/woff',
      '.woff2' => 'font/woff2',
      '.ttf' => 'font/ttf',
      '.otf' => 'font/otf',
      '.map' => 'application/json',
      '.txt' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }
}
