import 'dart:convert';

import '../config/app_config.dart';
import 'backend_http.dart';

/// 分享失败（含服务端返回的可读原因）。
class ShareException implements Exception {
  const ShareException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// AI 对话分享服务。
///
/// 只做一件事：把一段对话内容提交给账号后端，换回一个只读分享链接。
/// 需要登录（携带账号 token）；未配置后端或网络失败时抛出 [ShareException]。
class ShareService {
  ShareService._();

  static final ShareService instance = ShareService._();

  Future<String> createShare({
    required String token,
    required String title,
    required String content,
  }) async {
    final base = AppConfig.accountBackendBase;
    if (base.isEmpty) {
      throw const ShareException('未配置账号后端，暂时无法生成分享链接');
    }
    if (token.trim().isEmpty) {
      throw const ShareException('请先登录后再分享');
    }
    final body = jsonEncode({
      'title': title.trim().isEmpty ? 'AI 对话分享' : title.trim(),
      'content': content,
    });
    try {
      final response = await BackendHttp.client
          .post(
            Uri.parse('$base/api/share'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic> data;
      try {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        data = const {};
      }
      if (response.statusCode != 200) {
        throw ShareException(
          (data['error'] ?? '分享失败（HTTP ${response.statusCode}）').toString(),
        );
      }
      final url = (data['url'] ?? '').toString();
      if (url.isEmpty) {
        throw const ShareException('服务端未返回分享链接');
      }
      return url;
    } on ShareException {
      rethrow;
    } catch (e) {
      throw ShareException('分享失败：$e');
    }
  }
}
