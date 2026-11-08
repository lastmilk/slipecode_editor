import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import '../models/credits.dart';
import '../services/account_service.dart';
import '../services/avatar_service.dart';
import '../services/wallpaper_sync_service.dart';
import 'settings_provider.dart';

enum AccountStatus { signedOut, signingIn, signedIn }

/// SLIPE 独立账号状态管理
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

  // 商业化：积分 / 内置模型
  List<BuiltinLlmModel> _builtinModels = const [];
  String _defaultBuiltinModelId = '';
  List<CreditLogEntry> _creditLogs = const [];
  BillingInfo _billing = const BillingInfo();
  bool _checkedInToday = false;
  bool _loadingCredits = false;

  AccountStatus get status => _status;
  AccountUser? get user => _user;

  int get credits => _user?.credits ?? 0;
  List<BuiltinLlmModel> get builtinModels => _builtinModels;
  String get defaultBuiltinModelId => _defaultBuiltinModelId;
  List<CreditLogEntry> get creditLogs => _creditLogs;
  BillingInfo get billing => _billing;
  bool get checkedInToday => _checkedInToday;
  bool get loadingCredits => _loadingCredits;

  /// 当前账号 token（用于 SLIPE 云端模型 / 同步接口）
  String? get token => _token;
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
      _user = await AccountService.instance
          .me(token)
          .timeout(const Duration(seconds: 10));
      _token = token;
      _status = AccountStatus.signedIn;
      _safeNotify();
      await _syncAfterLogin();
    } catch (e) {
      debugPrint('恢复账号登录失败：$e');
      // 网络不可达/后端未部署时降级为未登录，但保留 token 以便下次重试；
      // 只有确定性失败（如 401）才清除
      final isNetworkError = e is TimeoutException || e is SocketException;
      if (!isNetworkError) {
        await AccountService.instance.clearToken();
      }
      _token = null;
      _status = AccountStatus.signedOut;
      _safeNotify();
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
    required String phone,
    required String smsCode,
    Map<String, dynamic>? captcha,
    String captchaPlatform = 'android',
  }) async {
    return _authenticate(
      () => AccountService.instance.register(
        email: email,
        password: password,
        displayName: displayName,
        phone: phone,
        smsCode: smsCode,
        captcha: captcha,
        captchaPlatform: captchaPlatform,
      ),
    );
  }

  /// 发送注册短信验证码，返回 (ok, dev, devCode)
  Future<(bool, bool, String?)> sendSmsCode(String phone) async {
    try {
      return await AccountService.instance.sendSmsCode(phone);
    } catch (e) {
      _error = '$e';
      _safeNotify();
      return (false, false, null);
    }
  }

  Future<bool> login({
    required String email,
    required String password,
    Map<String, dynamic>? captcha,
    String captchaPlatform = 'android',
  }) async {
    return _authenticate(
      () => AccountService.instance.login(
        email: email,
        password: password,
        captcha: captcha,
        captchaPlatform: captchaPlatform,
      ),
    );
  }

  Future<bool> _authenticate(
    Future<(String, AccountUser)> Function() action,
  ) async {
    if (!isConfigured) {
      _error = t('account.error.backendNotConfigured');
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
      // 登录后：设置 → 头像 → 壁纸（本地项目目录不再自动同步）
      await _syncAfterLogin();
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
    _builtinModels = const [];
    _defaultBuiltinModelId = '';
    _creditLogs = const [];
    _billing = const BillingInfo();
    _checkedInToday = false;
    // 退出账号后不再保留账号头像（避免首页仍显示已退出账号的头像）
    await _settings.clearAvatar();
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
        _error = t('account.error.settingsSyncFailed', {'error': '$e'});
        _safeNotify();
      }
    });
  }

  /// 立即从云端拉取设置并应用
  Future<bool> syncNow() async {
    if (!isSignedIn) {
      _error = t('account.error.signInFirst');
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
      _error = t('account.error.syncFailed', {'error': '$e'});
      _safeNotify();
      return false;
    }
  }

  Future<void> _pullSettings() async {
    final remote = await AccountService.instance.fetchSettings(_token!);
    if (remote == null || remote.isEmpty) {
      // 云端还没有设置：把本地设置作为初始版本（API Key 是否上传取决于用户开关）
      await AccountService.instance.pushSettings(
        _token!,
        _settings.settings.toJson(
          includeSecrets: _settings.settings.llmCloudSync,
        ),
      );
      _lastSyncAt = DateTime.now();
    } else {
      await _settings.applyRemote(remote);
      _lastSyncAt = DateTime.now();
    }
    _safeNotify();
  }

  /// 登录后的完整同步：设置 → 头像 → 壁纸
  ///
  /// 注意：不再同步本机项目目录列表。需要拉取云端仓库时，
  /// 由用户手动进入首页右上角的「同步仓库」页面选择仓库并拉取。
  Future<void> _syncAfterLogin() async {
    try {
      await _pullSettings();
    } catch (e) {
      _error = t('account.error.settingsSyncFailed', {'error': '$e'});
      _safeNotify();
    }
    await _syncAvatar();
    await _syncWallpaper();
    await _syncBilling();
  }

  /// 登录后同步积分、内置模型与充值套餐
  Future<void> _syncBilling() async {
    await refreshBuiltinModels();
    await refreshCredits();
    await loadBillingPlans();
  }

  /// 刷新内置模型列表
  Future<void> refreshBuiltinModels() async {
    if (!isSignedIn) return;
    try {
      final result = await AccountService.instance.fetchLlmModels(_token!);
      _builtinModels = result.models;
      if (result.defaultId.isNotEmpty) {
        _defaultBuiltinModelId = result.defaultId;
      } else if (_builtinModels.isNotEmpty) {
        _defaultBuiltinModelId = _builtinModels.first.id;
      }
      _safeNotify();
    } catch (e) {
      debugPrint('内置模型列表获取失败：$e');
    }
  }

  /// 刷新积分余额与签到状态
  Future<void> refreshCredits() async {
    if (!isSignedIn) return;
    try {
      final result = await AccountService.instance.fetchCredits(_token!);
      _checkedInToday = result.checkedInToday;
      _applyCredits(result.credits);
    } catch (e) {
      debugPrint('积分刷新失败：$e');
    }
  }

  /// 拉取积分明细
  Future<void> refreshCreditLogs() async {
    if (!isSignedIn) return;
    try {
      _creditLogs = await AccountService.instance.fetchCreditLogs(_token!);
      _safeNotify();
    } catch (e) {
      debugPrint('积分明细获取失败：$e');
    }
  }

  /// 拉取充值套餐（公开接口）
  Future<void> loadBillingPlans() async {
    if (!isConfigured) return;
    try {
      _billing = await AccountService.instance.fetchBillingPlans();
      _safeNotify();
    } catch (e) {
      debugPrint('充值套餐获取失败：$e');
    }
  }

  /// 每日签到
  Future<(bool, String)> checkin() async {
    if (!isSignedIn) return (false, '请先登录');
    try {
      final result = await AccountService.instance.checkin(_token!);
      _checkedInToday = true;
      _applyCredits(result.credits);
      return (result.ok, result.message);
    } catch (e) {
      return (false, '$e');
    }
  }

  /// 兑换激活码
  Future<(bool, String)> redeemActivationCode(String code) async {
    if (!isSignedIn) return (false, '请先登录');
    try {
      final result = await AccountService.instance.redeemActivationCode(_token!, code);
      _applyCredits(result.credits);
      await refreshCreditLogs();
      return (result.ok, result.message);
    } catch (e) {
      return (false, '$e');
    }
  }

  /// AI 调用扣费后同步余额（后端流式响应会返回最新余额）
  void updateCredits(int value) {
    if (value == credits) return;
    _applyCredits(value);
  }

  void _applyCredits(int value) {
    final user = _user;
    if (user == null) return;
    _user = user.copyWith(credits: value);
    _safeNotify();
  }

  /// 下载账号头像为本地头像
  Future<void> _syncAvatar() async {
    final user = _user;
    if (user == null || user.avatarUrl.isEmpty) return;
    try {
      final path = await AvatarService.downloadToLocal(user.avatarUrl);
      if (path != null) {
        await _settings.applyServerAvatarPath(path);
      }
    } catch (e) {
      debugPrint('头像同步失败：$e');
    }
  }

  /// 云端壁纸有更新时自动下载
  Future<void> _syncWallpaper() async {
    if (_token == null) return;
    try {
      final result = await WallpaperSyncService.downloadIfNewer(
        token: _token!,
        settings: _settings.settings,
      );
      if (result != null) {
        await _settings.applyServerWallpaperPath(result.path, result.version);
      }
    } catch (e) {
      debugPrint('壁纸同步失败：$e');
    }
  }

  /// 上传本地头像到账号（本地头像已先保存）
  Future<bool> uploadAvatar(String localPath) async {
    if (!isSignedIn) return false;
    try {
      await AvatarService.uploadFile(token: _token!, path: localPath);
      return true;
    } catch (e) {
      _error = t('account.error.avatarUploadFailed', {'error': '$e'});
      _safeNotify();
      return false;
    }
  }

  /// 上传本地壁纸到云端（类型/大小/网络不满足时静默跳过）
  Future<bool> uploadWallpaper(String localPath) async {
    if (!isSignedIn) return false;
    try {
      final version = await WallpaperSyncService.uploadIfEligible(
        token: _token!,
        settings: _settings.settings,
        path: localPath,
      );
      if (version == null) return false;
      await _settings.applyServerWallpaperPath(localPath, version);
      return true;
    } catch (e) {
      _error = t('account.error.wallpaperUploadFailed', {'error': '$e'});
      _safeNotify();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pushTimer?.cancel();
    super.dispose();
  }
}
