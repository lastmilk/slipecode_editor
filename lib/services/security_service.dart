import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_platform.dart';

/// 应用安全服务
///
/// - 解锁密码仅保存加盐 SHA-256 摘要
/// - 生物认证调用系统能力（Android BiometricPrompt / iOS Face ID·Touch ID）
/// - 生物认证失败时回退到密码校验
///
/// 持久化说明：
/// 早期版本把密码摘要与开关保存在 flutter_secure_storage，
/// 部分设备（Keystore 解密失败 / 数据丢失）重启后会全部读不到，
/// 表现为「设置成功 → 重启后应用锁消失、安全页显示未设置」。
/// 现改为 SharedPreferences（存的是加盐摘要，无法反推密码），
/// 首次读取时自动从旧的 secure storage 迁移。
class SecurityService {
  SecurityService._();

  static final SecurityService instance = SecurityService._();

  /// 主动锁定信号（桌面 Ctrl+L 触发），AppLockGate 监听后立即上锁
  static final ValueNotifier<int> relockSignal = ValueNotifier<int>(0);

  static void requestRelock() {
    relockSignal.value++;
  }

  static const _kHash = 'slipe_app_lock_hash';
  static const _kSalt = 'slipe_app_lock_salt';
  static const _kBiometric = 'slipe_app_lock_biometric';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();

  bool _migrated = false;

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  /// 一次性把旧 secure storage 数据迁移到 SharedPreferences
  Future<void> _ensureMigrated() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final prefs = await _prefs();
      // 本地已有数据则无需迁移
      if (prefs.getString(_kHash) != null) return;
      final hash = await _secure.read(key: _kHash);
      final salt = await _secure.read(key: _kSalt);
      final biometric = await _secure.read(key: _kBiometric);
      if (hash != null && hash.isNotEmpty) {
        await prefs.setString(_kHash, hash);
        if (salt != null && salt.isNotEmpty) {
          await prefs.setString(_kSalt, salt);
        }
        await prefs.setString(_kBiometric, biometric == '1' ? '1' : '0');
        // 迁移完成后清理旧位置，避免两份数据漂移
        await _secure.delete(key: _kHash);
        await _secure.delete(key: _kSalt);
        await _secure.delete(key: _kBiometric);
      }
    } catch (e) {
      debugPrint('应用锁数据迁移失败（忽略，继续使用新存储）：$e');
    }
  }

  Future<bool> hasPassword() async {
    await _ensureMigrated();
    final prefs = await _prefs();
    final hash = prefs.getString(_kHash);
    return hash != null && hash.isNotEmpty;
  }

  /// 设置 / 修改解锁密码
  Future<void> setPassword(String password) async {
    await _ensureMigrated();
    final salt = _randomSalt();
    final prefs = await _prefs();
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kHash, _hash(password, salt));
  }

  /// 校验密码
  Future<bool> verifyPassword(String password) async {
    await _ensureMigrated();
    final prefs = await _prefs();
    final salt = prefs.getString(_kSalt);
    final hash = prefs.getString(_kHash);
    if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) {
      return false;
    }
    return _hash(password, salt) == hash;
  }

  Future<bool> isBiometricEnabled() async {
    await _ensureMigrated();
    final prefs = await _prefs();
    return prefs.getString(_kBiometric) == '1';
  }

  Future<void> setBiometricEnabled(bool value) async {
    await _ensureMigrated();
    final prefs = await _prefs();
    await prefs.setString(_kBiometric, value ? '1' : '0');
  }

  /// 设备是否具备可用的生物认证
  ///
  /// 以 [isDeviceSupported] 为准：Android 上「仅设置锁屏密码」的设备也能
  /// 通过 BiometricPrompt 的备用凭据验证，此时 [canCheckBiometrics] 为 false，
  /// 若强制要求会导致设置页误报「设备不支持」。
  Future<bool> biometricAvailable() async {
    // 桌面端不提供生物认证，统一使用解锁密码
    if (DesktopPlatform.isDesktop) return false;
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
    if (DesktopPlatform.isDesktop) return false;
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
    await _ensureMigrated();
    final prefs = await _prefs();
    await prefs.remove(_kHash);
    await prefs.remove(_kSalt);
    await prefs.setString(_kBiometric, '0');
  }

  static String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String _hash(String password, String salt) =>
      sha256.convert(utf8.encode('$salt::$password')).toString();
}
