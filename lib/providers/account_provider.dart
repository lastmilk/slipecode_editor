import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/account_service.dart';
import 'settings_provider.dart';

enum AccountStatus { signedOut, signingIn, signedIn }

/// SlipCode 独立账号状态管理
///
/// 登录后自动从后端拉取偏好设置；本地修改设置时防抖推送到后端，
/// 实现不同设备间的设置同步。
class AccountProvider extends ChangeNotifier {
  AccountProvider(this._settings);

  final SettingsProvider _settings;

  AccountStatus _status = AccountStatus.signedOut;
  AccountUser? _user;
  String? _token;
  String? _error;
  DateTime? _lastSyncAt;
  Timer? _pushTimer;
  bool _disposed = false;

  AccountStatus get status => _status;
  AccountUser? get user => _user;
  String? get error => _error;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get isSignedIn => _status == AccountStatus.signedIn && _token != null;
  bool get isConfigured => AccountService.instance.isConfigured;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    if (!isConfigured) {
      _status = AccountStatus.signedOut;
      _safeNotify();
      return;
    }
    final token = await AccountService.instance.savedToken;
    if (token == null || token.isEmpty) {
      _status = AccountStatus.signedOut;
      _safeNotify();
      return;
    }
    try {
      _user = await AccountService.instance.me(token);
      _token = token;
      _status = AccountStatus.signedIn;
      _safeNotify();
      await _pullSettings();
    } catch (e) {
      debugPrint('恢复账号登录失败：$e');
      await AccountService.instance.clearToken();
      _token = null;
      _status = AccountStatus.signedOut;
      _safeNotify();
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    return _authenticate(
      () => AccountService.instance.register(
        email: email,
        password: password,
        displayName: displayName,
      ),
    );
  }

  Future<bool> login({
    required String email,
    required String password,
  }) async {
    return _authenticate(
      () => AccountService.instance.login(email: email, password: password),
    );
  }

  Future<bool> _authenticate(
    Future<(String, AccountUser)> Function() action,
  ) async {
    if (!isConfigured) {
      _error = '未配置账号后端（ACCOUNT_BACKEND_BASE_URL）';
      _safeNotify();
      return false;
    }
    _status = AccountStatus.signingIn;
    _error = null;
    _safeNotify();
    try {
      final (token, user) = await action();
      await AccountService.instance.saveToken(token);
      _token = token;
      _user = user;
      _status = AccountStatus.signedIn;
      _safeNotify();
      // 登录后优先使用云端设置
      await _pullSettings();
      return true;
    } catch (e) {
      _error = '$e';
      _status = AccountStatus.signedOut;
      _safeNotify();
      return false;
    }
  }

  Future<void> signOut() async {
    _pushTimer?.cancel();
    await AccountService.instance.clearToken();
    _token = null;
    _user = null;
    _status = AccountStatus.signedOut;
    _lastSyncAt = null;
    _safeNotify();
  }

  /// 本地设置变更后推送到后端（防抖 1.5s）
  Future<void> pushSettingsIfLoggedIn(Map<String, dynamic> settings) async {
    if (!isSignedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 1500), () async {
      try {
        await AccountService.instance.pushSettings(_token!, settings);
        _lastSyncAt = DateTime.now();
        _error = null;
        _safeNotify();
      } catch (e) {
        _error = '设置同步失败：$e';
        _safeNotify();
      }
    });
  }

  /// 立即从云端拉取设置并应用
  Future<bool> syncNow() async {
    if (!isSignedIn) {
      _error = '请先登录 SlipCode 账号';
      _safeNotify();
      return false;
    }
    try {
      await _pullSettings();
      _lastSyncAt = DateTime.now();
      _error = null;
      _safeNotify();
      return true;
    } catch (e) {
      _error = '同步失败：$e';
      _safeNotify();
      return false;
    }
  }

  Future<void> _pullSettings() async {
    final remote = await AccountService.instance.fetchSettings(_token!);
    if (remote == null || remote.isEmpty) {
      // 云端还没有设置：把本地设置作为初始版本
      await AccountService.instance.pushSettings(
        _token!,
        _settings.settings.toJson(),
      );
      _lastSyncAt = DateTime.now();
    } else {
      await _settings.applyRemote(remote);
      _lastSyncAt = DateTime.now();
    }
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _pushTimer?.cancel();
    super.dispose();
  }
}
