import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 本机设备标识：用于登录设备管理
class DeviceInfoService {
  DeviceInfoService._();

  static const _key = 'slipe_device_id';

  static String _osLabel(String os) {
    switch (os) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      default:
        return os;
    }
  }

  /// 返回 `{id, name, platform}`，随登录 / 注册请求提交
  static Future<Map<String, dynamic>> current() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString(_key, id);
    }

    final platform = Platform.operatingSystem;
    final version = Platform.operatingSystemVersion
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final shortVersion = version.length > 36 ? version.substring(0, 36) : version;
    return {
      'id': 'dev_$id',
      'name': '${_osLabel(platform)}${shortVersion.isEmpty ? '' : ' · $shortVersion'}',
      'platform': platform,
    };
  }
}
