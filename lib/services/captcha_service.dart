import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';

/// 极验验证结果（交由后端二次校验）
class CaptchaResult {
  final String lotNumber;
  final String captchaOutput;
  final String passToken;
  final String genTime;

  const CaptchaResult({
    required this.lotNumber,
    required this.captchaOutput,
    required this.passToken,
    required this.genTime,
  });

  Map<String, dynamic> toJson() => {
        'lot_number': lotNumber,
        'captcha_output': captchaOutput,
        'pass_token': passToken,
        'gen_time': genTime,
      };
}

/// 人机验证异常（用户取消 / 验证失败 / SDK 异常）
class CaptchaException implements Exception {
  final String message;
  const CaptchaException(this.message);

  @override
  String toString() => message;
}

/// 极验 GT4 客户端
///
/// 仅 Android 原生支持；其它平台返回 null（由后端按 `captchaPlatform`
/// 决定是否放行）。
class CaptchaService {
  CaptchaService._();

  static const MethodChannel _channel = MethodChannel('slipecode/geetest');

  /// 当前平台是否支持原生极验
  static bool get isPlatformSupported => !kIsWeb && Platform.isAndroid;

  /// 是否需要执行验证（平台支持且已配置）
  static bool get isSupported =>
      isPlatformSupported && AppConfig.isGeetestConfigured;

  /// 平台标识，随请求带给后端
  static String get platformFlag =>
      isPlatformSupported ? 'android' : 'unsupported';

  /// 弹出极验验证，成功返回结果；用户取消或失败抛 [CaptchaException]
  static Future<CaptchaResult?> verify() async {
    if (!isSupported) return null;
    try {
      final data = await _channel
          .invokeMapMethod<String, dynamic>(
            'verify',
            {'captchaId': AppConfig.geetestCaptchaId},
          )
          .timeout(const Duration(seconds: 60));
      if (data == null || (data['lot_number'] ?? '').toString().isEmpty) {
        throw const CaptchaException('人机验证未返回有效结果');
      }
      return CaptchaResult(
        lotNumber: (data['lot_number'] ?? '').toString(),
        captchaOutput: (data['captcha_output'] ?? '').toString(),
        passToken: (data['pass_token'] ?? '').toString(),
        genTime: (data['gen_time'] ?? '').toString(),
      );
    } on PlatformException catch (e) {
      throw CaptchaException(e.message ?? '人机验证失败');
    } on MissingPluginException {
      // 旧安装包 / 非 Android：忽略，由后端判断
      return null;
    }
  }
}
