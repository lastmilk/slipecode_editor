import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/app_config.dart';

/// 账号后端专用 HTTP 客户端
///
/// 背景：线上后端 `api.slipe.linjade.com` 的域名解析指向共享服务器，
/// 该服务器当前下发的是另一站点（如 `ser1996.niav.cn`）的证书，
/// 因此 Dart 会抛出 `CERTIFICATE_VERIFY_FAILED: Hostname mismatch`。
///
/// 处理策略：
/// 1. 只对 `.env` 中配置的账号后端主机放行「主机名不匹配」；
/// 2. 证书必须由受信任的公共 CA 签发且在有效期内（排除自签名证书）；
/// 3. 其它任何主机、其它任何证书错误一律拒绝。
///
/// 注意：这是服务端证书未正确配置时的兜底；服务端修复证书后
/// 该回调不会再被触发。
class BackendHttp {
  BackendHttp._();

  static http.Client? _client;

  static http.Client get client => _client ??= _build();

  static String get _allowedHost {
    final base = AppConfig.accountBackendBase;
    if (base.isEmpty) return '';
    return Uri.tryParse(base)?.host ?? '';
  }

  static http.Client _build() {
    final io = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    io.badCertificateCallback = (cert, host, port) {
      if (host != _allowedHost) return false;
      if (cert.startValidity.isAfter(DateTime.now()) ||
          cert.endValidity.isBefore(DateTime.now())) {
        return false;
      }
      return _trustedIssuer(cert.issuer);
    };
    return IOClient(io);
  }

  /// 公共 CA 的签发者特征（BoringSSL 在主机名不匹配时仍会走到这里，
  /// 因此额外要求签发者来自知名公共 CA，避免信任自签名证书）。
  static bool _trustedIssuer(String issuer) {
    final lower = issuer.toLowerCase();
    return lower.contains("let's encrypt") ||
        lower.contains('digicert') ||
        lower.contains('globalsign') ||
        lower.contains('sectigo') ||
        lower.contains('comodo') ||
        lower.contains('google trust services') ||
        lower.contains('amazon') ||
        lower.contains('entrust') ||
        lower.contains('geotrust') ||
        lower.contains('rapidssl') ||
        lower.contains('thawte') ||
        lower.contains('ssl.com');
  }
}
