import 'dart:async';
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
  ///
  /// 原生侧会在 60s 后主动超时；这里再留一点余量做兜底。
  static Future<CaptchaResult?> verify() async {
    if (!isSupported) return null;
    try {
      final data = await _channel
          .invokeMapMethod<String, dynamic>(
            'verify',
            {'captchaId': AppConfig.geetestCaptchaId},
          )
          .timeout(const Duration(seconds: 75));
      if (data == null || (data['lot_number'] ?? '').toString().isEmpty) {
        throw const CaptchaException('人机验证未返回有效结果');
      }
      return CaptchaResult(
        lotNumber: (data['lot_number'] ?? '').toString(),
        captchaOutput: (data['captcha_output'] ?? '').toString(),
        passToken: (data['pass_token'] ?? '').toString(),
        genTime: (data['gen_time'] ?? '').toString(),
      );
    } on TimeoutException {
      // 让原生侧关闭验证窗口，避免窗口残留
      try {
        await _channel.invokeMethod<bool>('cancel');
      } catch (_) {}
      throw const CaptchaException('人机验证超时，请重试');
    } on PlatformException catch (e) {
      throw CaptchaException(_messageFor(e));
    } on MissingPluginException {
      // 旧安装包 / 非 Android：忽略，由后端判断
      return null;
    }
  }

  /// 把原生错误码翻译成用户可读的提示
  static String _messageFor(PlatformException e) {
    switch (e.code) {
      case 'CAPTCHA_UNSUPPORTED':
        return '当前设备不支持人机验证，请升级系统 WebView';
      case 'CAPTCHA_CONFIG':
        return '人机验证未配置，请稍后再试';
      case 'CAPTCHA_BUSY':
        return '上一次人机验证还在进行中';
      case 'CAPTCHA_TIMEOUT':
        return '人机验证超时，请重试';
      case 'CAPTCHA_CANCELLED':
        return '已取消人机验证';
      case 'CAPTCHA_FAILED':
        return '人机验证未通过，请重试';
      case 'CAPTCHA_PARSE':
        return '人机验证结果异常，请重试';
      default:
        return (e.message?.isNotEmpty ?? false) ? e.message! : '人机验证失败';
    }
  }
}
