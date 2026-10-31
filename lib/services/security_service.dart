import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// 应用安全服务
///
/// - 解锁密码仅保存加盐 SHA-256 摘要（flutter_secure_storage）
/// - 生物认证调用系统能力（Android BiometricPrompt / iOS Face ID·Touch ID）
/// - 生物认证失败时回退到密码校验
class SecurityService {
  SecurityService._();

  static final SecurityService instance = SecurityService._();

  static const _kHash = 'slipe_app_lock_hash';
  static const _kSalt = 'slipe_app_lock_salt';
  static const _kBiometric = 'slipe_app_lock_biometric';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> hasPassword() async {
    final hash = await _storage.read(key: _kHash);
    return hash != null && hash.isNotEmpty;
  }

  /// 设置 / 修改解锁密码
  Future<void> setPassword(String password) async {
    final salt = _randomSalt();
    await _storage.write(key: _kSalt, value: salt);
    await _storage.write(key: _kHash, value: _hash(password, salt));
  }

  /// 校验密码
  Future<bool> verifyPassword(String password) async {
    final salt = await _storage.read(key: _kSalt);
    final hash = await _storage.read(key: _kHash);
    if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) {
      return false;
    }
    return _hash(password, salt) == hash;
  }

  Future<bool> isBiometricEnabled() async =>
      (await _storage.read(key: _kBiometric)) == '1';

  Future<void> setBiometricEnabled(bool value) async {
    await _storage.write(key: _kBiometric, value: value ? '1' : '0');
  }

  /// 设备是否具备可用的生物认证
  ///
  /// 以 [isDeviceSupported] 为准：Android 上「仅设置锁屏密码」的设备也能
  /// 通过 BiometricPrompt 的备用凭据验证，此时 [canCheckBiometrics] 为 false，
  /// 若强制要求会导致设置页误报「设备不支持」。
  Future<bool> biometricAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('生物认证能力检测失败：$e');
      return false;
    }
  }

  /// 调起系统生物认证
  ///
  /// 已录入生物特征时只允许生物识别；设备仅有锁屏密码时回退到
  /// 系统凭据（PIN / 图案 / 密码），避免直接抛错导致无法解锁。
  Future<bool> authenticate({String reason = '验证身份以解锁 SLIPE'}) async {
    try {
      final enrolled = await _auth.getAvailableBiometrics();
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: enrolled.isNotEmpty,
          stickyAuth: true,
        ),
      );
    } on PlatformException catch (e) {
      // NotEnrolled / NotAvailable / PermanentlyLocked 等
      debugPrint('生物认证调用失败（${e.code}）：${e.message}');
      return false;
    } catch (e) {
      debugPrint('生物认证失败：$e');
      return false;
    }
  }

  /// 关闭应用锁并清除密码
  Future<void> disable() async {
    await _storage.delete(key: _kHash);
    await _storage.delete(key: _kSalt);
    await _storage.write(key: _kBiometric, value: '0');
  }

  static String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String _hash(String password, String salt) =>
      sha256.convert(utf8.encode('$salt::$password')).toString();
}
