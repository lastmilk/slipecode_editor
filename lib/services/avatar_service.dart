import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/account_service.dart';

/// 账号头像同步
///
/// 云端头像是唯一真源：登录后下载到本地 `avatars/account_<hash>.jpg`，
/// 本地更换头像后上传；首页/账号页都读取本地副本，离线也能显示。
class AvatarService {
  AvatarService._();

  static String mimeForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.png') return 'image/png';
    if (ext == '.webp') return 'image/webp';
    return 'image/jpeg';
  }

  /// 下载账号头像到本地，返回本地路径（失败返回 null）
  static Future<String?> downloadToLocal(String avatarUrl) async {
    if (avatarUrl.isEmpty) return null;
    final bytes = await AccountService.instance.downloadAvatar(avatarUrl);
    if (bytes == null) return null;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'avatars'));
    await dir.create(recursive: true);
    final hash = avatarUrl.hashCode.toRadixString(16);
    final file = File(p.join(dir.path, 'account_$hash.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 上传本地头像文件到账号
  static Future<String?> uploadFile({
    required String token,
    required String path,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return AccountService.instance.uploadAvatar(
      token,
      bytes,
      mimeForPath(path),
    );
  }
}
