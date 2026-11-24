import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'toolchain_models.dart';

/// 流式下载器（HTTP / HTTPS）。
///
/// 说明：不实现断点续传；取消或失败时会清理 `.part` 文件。
class ToolchainDownloader {
  /// [onProgress] 会按约 120ms 节流回调，避免高频刷新界面。
  Future<File> download({
    required String url,
    required File destination,
    required ToolchainCancelToken cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final part = File('${destination.path}.part');
    await destination.parent.create(recursive: true);
    if (await part.exists()) await part.delete();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    IOSink? sink;
    var lastNotify = DateTime.now();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'SLIPE-Editor/1.0');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      final total = response.contentLength;
      var received = 0;
      sink = part.openWrite();
      await for (final chunk in response) {
        cancelToken.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds >= 120) {
          lastNotify = now;
          onProgress?.call(received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      cancelToken.throwIfCancelled();
      onProgress?.call(received, total > 0 ? total : received);
      if (await destination.exists()) await destination.delete();
      return await part.rename(destination.path);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {
        // 忽略关闭失败
      }
      client.close(force: true);
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {
          // 忽略清理失败
        }
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 校验 SHA-256；[expected] 为空时直接返回 true。
  Future<bool> verifySha256(File file, String? expected) async {
    if (expected == null || expected.trim().isEmpty) return true;
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString().toLowerCase() == expected.trim().toLowerCase();
    } catch (e) {
      debugPrint('计算 SHA-256 失败：$e');
      return false;
    }
  }
}
