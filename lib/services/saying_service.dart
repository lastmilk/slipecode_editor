import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 每日一句服务
///
/// 数据源：https://uapis.cn/api/v1/saying（返回 {"text": "..."}）。
/// 每次拉取成功后写入本地缓存；离线时从缓存随机取一条。
class SayingService {
  SayingService._();

  static final SayingService instance = SayingService._();

  static const _cacheKey = 'slipe_saying_cache';
  static const _maxCached = 20;
  static const _apiUrl = 'https://uapis.cn/api/v1/saying';

  static const _fallbacks = [
    '在 Flutter 中编辑 Flutter。',
    '代码写好了，世界就不一样了。',
    '保持热爱，奔赴山海。',
  ];

  final _random = Random();

  /// 立即可用的语句：从缓存随机取一条；无缓存时返回内置文案。
  Future<String> cached() async {
    final items = await _readCache();
    if (items.isEmpty) return _fallbacks[_random.nextInt(_fallbacks.length)];
    return items[_random.nextInt(items.length)];
  }

  /// 拉取一条新语句；成功则写入缓存并返回，失败返回 null。
  Future<String?> fetchFresh() async {
    try {
      final res = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final text = _extractText(body);
      if (text == null || text.isEmpty) return null;
      await _addToCache(text);
      return text;
    } catch (_) {
      return null;
    }
  }

  /// 兼容多种返回形态：{"text":...} / {"data":{"text":...}} / {"saying":...}
  static String? _extractText(dynamic body) {
    if (body is String) return body;
    if (body is Map) {
      for (final key in ['text', 'saying', 'hitokoto']) {
        final v = body[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      final data = body['data'];
      if (data is Map) return _extractText(data);
      if (data is String) return data;
    }
    return null;
  }

  Future<List<String>> _readCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).whereType<String>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _addToCache(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await _readCache();
    items.remove(text); // 去重后置顶
    items.insert(0, text);
    if (items.length > _maxCached) {
      items.removeRange(_maxCached, items.length);
    }
    await prefs.setString(_cacheKey, jsonEncode(items));
  }
}
