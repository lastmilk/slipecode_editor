import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/desktop_platform.dart';
import '../services/security_service.dart';

/// 应用锁入口
///
/// 在设置中开启「应用锁」后，启动应用与从后台返回时需要：
/// 1. 通过系统生物认证；或
/// 2. 输入先前设置过的解锁密码。
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _locked = false;
  bool _loading = true;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SecurityService.relockSignal.addListener(_onRelockRequest);
    unawaited(_load());
  }

  void _onRelockRequest() {
    if (!_locked) unawaited(_relock());
  }

  Future<void> _load() async {
    // 桌面端只支持密码解锁；移动端沿用「应用锁开关」判断
    final enabled = DesktopPlatform.isDesktop
        ? await SecurityService.instance.hasPassword()
        : await SecurityService.instance.isBiometricEnabled();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _locked = enabled;
    });
    if (enabled && !DesktopPlatform.isDesktop) {
      // 启动时自动尝试一次生物认证
      unawaited(_tryBiometric());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt == null) return;
      // 短暂切后台（如下拉通知栏、系统授权弹窗）不重复上锁
      if (DateTime.now().difference(pausedAt).inSeconds < 20) return;
      if (!_locked) {
        unawaited(_relock());
      }
    }
  }

  Future<void> _relock() async {
    final enabled = DesktopPlatform.isDesktop
        ? await SecurityService.instance.hasPassword()
        : await SecurityService.instance.isBiometricEnabled();
    if (!mounted || !enabled) return;
    setState(() => _locked = true);
    if (!DesktopPlatform.isDesktop) await _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    if (DesktopPlatform.isDesktop) return;
    final ok = await SecurityService.instance.authenticate();
    if (!mounted) return;
    if (ok) {
      setState(() => _locked = false);
    }
  }

  Future<void> _unlockWithPassword(String password) async {
    final ok = await SecurityService.instance.verifyPassword(password);
    if (!mounted) return;
    if (ok) {
      setState(() => _locked = false);
      return;
    }
    throw const _WrongPassword();
  }

  @override
  void dispose() {
    SecurityService.relockSignal.removeListener(_onRelockRequest);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // 读取持久化状态期间的占位页：跟随主题色，避免突兀黑屏
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Scaffold(
        backgroundColor: isDark
            ? const Color(0xFF121212)
            : const Color(0xFFF5F7FA),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_locked) return widget.child;
    return _LockScreen(
      onPassword: _unlockWithPassword,
      onBiometric: _tryBiometric,
      showBiometric: !DesktopPlatform.isDesktop,
    );
  }
}

class _WrongPassword implements Exception {
  const _WrongPassword();
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({
    required this.onPassword,
    required this.onBiometric,
    this.showBiometric = true,
  });

  final Future<void> Function(String password) onPassword;
  final Future<void> Function() onBiometric;
  final bool showBiometric;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _hasPassword = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkPassword());
  }

  Future<void> _checkPassword() async {
    final has = await SecurityService.instance.hasPassword();
    if (!mounted) return;
    setState(() => _hasPassword = has);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onPassword(_password.text);
      if (mounted) _password.clear();
    } on _WrongPassword {
      if (mounted) {
        setState(() => _error = t('lock.wrongPassword'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onBiometric();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = null;
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF121212)
          : const Color(0xFFF5F7FA),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 56,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t('lock.title'),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t('lock.subtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofocus: _hasPassword,
                    enabled: _hasPassword && !_busy,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: t('lock.passwordHint'),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (!_hasPassword) ...[
                    const SizedBox(height: 10),
                    Text(
                      t('lock.noPassword'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _hasPassword && !_busy ? _submit : null,
                      icon: const Icon(Icons.password, size: 18),
                      label: Text(t('lock.unlock')),
                    ),
                  ),
                  if (widget.showBiometric) ...[
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _busy ? null : _biometric,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(t('lock.biometric')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
