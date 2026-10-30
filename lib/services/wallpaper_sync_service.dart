import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import 'account_service.dart';
import 'network_policy.dart';

/// 壁纸云同步
///
/// 限制：
/// - 只有静态图片（png / jpg / webp）参与云同步；
/// - GIF / MP4 动态壁纸仅保存在本机；
/// - 超过 5MB 不上传；
/// - 仅在账号已登录且当前网络符合策略时执行。
class WallpaperSyncService {
  WallpaperSyncService._();

  static const int maxBytes = 5 * 1024 * 1024;
  static const Set<String> syncableExts = {'png', 'jpg', 'jpeg', 'webp'};
  static const Set<String> localOnlyExts = {'gif', 'mp4'};

  static String extOf(String path) =>
      p.extension(path).replaceFirst('.', '').toLowerCase();

  /// 该文件类型是否允许上传云端
  static bool isSyncablePath(String path) => syncableExts.contains(extOf(path));

  /// 本地壁纸是否可以上传（登录 + 网络 + 类型 + 大小）
  static Future<bool> canUpload({
    required String token,
    required AppSettings settings,
    required String path,
  }) async {
    if (token.isEmpty || path.isEmpty) return false;
    if (!isSyncablePath(path)) return false;
    final file = File(path);
    if (!file.existsSync()) return false;
    final size = await file.length();
    if (size > maxBytes) return false;
    return NetworkPolicy.canSyncNow(settings);
  }

  /// 上传本地壁纸；成功返回云端版本号，否则 null
  static Future<String?> uploadIfEligible({
    required String token,
    required AppSettings settings,
    required String path,
  }) async {
    try {
      if (!await canUpload(token: token, settings: settings, path: path)) {
        return null;
      }
      final bytes = await File(path).readAsBytes();
      final mime = switch (extOf(path)) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      return await AccountService.instance.uploadWallpaper(token, bytes, mime);
    } catch (_) {
      return null;
    }
  }

  /// 云端有更新时下载到本地；返回 (本地路径, 版本号)
  static Future<({String path, String version})?> downloadIfNewer({
    required String token,
    required AppSettings settings,
  }) async {
    try {
      if (!await NetworkPolicy.canSyncNow(settings)) return null;
      final remote = await AccountService.instance.downloadWallpaper(token);
      if (remote == null || remote.version.isEmpty) return null;
      if (remote.version == settings.wallpaperCloudVersion) return null;

      final ext = remote.mime.contains('png')
          ? 'png'
          : remote.mime.contains('webp')
              ? 'webp'
              : 'jpg';
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'backgrounds'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'cloud_wallpaper.$ext'));
      await file.writeAsBytes(remote.bytes, flush: true);
      return (path: file.path, version: remote.version);
    } catch (_) {
      return null;
    }
  }
}
