import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/app_settings.dart';

/// 云同步网络策略
///
/// - [never]：不同步
/// - [wifi]：仅 Wi-Fi / 以太网（默认）
/// - [any]：任意可用网络
class NetworkPolicy {
  NetworkPolicy._();

  static const String never = 'never';
  static const String wifi = 'wifi';
  static const String any = 'any';

  static const List<String> all = [wifi, any, never];

  static String label(String policy) => switch (policy) {
        any => '任意网络',
        never => '不同步',
        _ => '仅 Wi-Fi',
      };

  /// 当前网络是否允许执行云同步
  static Future<bool> canSyncNow(AppSettings settings) async {
    if (settings.syncNetwork == never) return false;
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty ||
          results.every((r) => r == ConnectivityResult.none)) {
        return false;
      }
      if (settings.syncNetwork == any) return true;
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      // 无法判定网络时不阻塞同步（避免误伤）
      return true;
    }
  }
}
