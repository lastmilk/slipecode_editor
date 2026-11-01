import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/account_provider.dart';
import '../services/captcha_service.dart';
import 'policy_screen.dart';

/// SLIPE 独立账号页面（注册 / 登录 / 退出）
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _smsController = TextEditingController();

  bool _registerMode = false;
  bool _submitting = false;
  bool _sendingSms = false;
  int _smsCountdown = 0;
  Timer? _smsTimer;
  String? _localError;

  /// 注册 / 登录前必须勾选同意《用户协议》与《隐私政策》
  bool _policyAgreed = false;

  @override
  void dispose() {
    _smsTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _smsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_policyAgreed) {
      setState(() => _localError = t('policy.mustAgreeToLogin'));
      return;
    }
    setState(() {
      _submitting = true;
      _localError = null;
    });
    final account = context.read<AccountProvider>();

    // 极验人机验证（仅 Android 原生；其它平台由后端按平台放行）
    Map<String, dynamic>? captcha;
    try {
      final result = await CaptchaService.verify();
      captcha = result?.toJson();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _localError = '$e';
      });
      return;
    }

    final ok = _registerMode
        ? await account.register(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            displayName: _nameController.text.trim(),
            phone: _phoneController.text.trim(),
            smsCode: _smsController.text.trim(),
            captcha: captcha,
            captchaPlatform: CaptchaService.platformFlag,
          )
        : await account.login(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            captcha: captcha,
            captchaPlatform: CaptchaService.platformFlag,
          );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok) _localError = account.error ?? t('account.actionFailed');
    });
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _registerMode
                ? t('account.registerSuccess')
                : t('account.loginSuccess'),
          ),
          backgroundColor: Colors.green,
        ),
      );
      _passwordController.clear();
    }
  }

  /// 发送注册短信验证码
  Future<void> _sendSms() async {
    final phone = _phoneController.text.trim();
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) {
      setState(() => _localError = t('account.invalidPhone'));
      return;
    }
    setState(() {
      _sendingSms = true;
      _localError = null;
    });
    final account = context.read<AccountProvider>();
    final (ok, dev, devCode) = await account.sendSmsCode(phone);
    if (!mounted) return;
    setState(() => _sendingSms = false);
    if (!ok) {
      setState(() => _localError = account.error ?? t('account.smsSendFailed'));
      return;
    }
    if (dev && devCode != null) {
      _smsController.text = devCode;
    }
    _startCountdown();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          dev
              ? t('account.smsDevFilled', {'code': '$devCode'})
              : t('account.smsSent'),
        ),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _startCountdown() {
    _smsTimer?.cancel();
    setState(() => _smsCountdown = 60);
    _smsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _smsCountdown -= 1;
        if (_smsCountdown <= 0) timer.cancel();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('account.title')),
        elevation: 0,
      ),
      body: account.isSignedIn
          ? _buildProfile(account, isDark)
          : _buildAuthForm(account, isDark),
    );
  }

  // ---------------------------------------------------------------------------
  // 已登录
  // ---------------------------------------------------------------------------

  Widget _buildProfile(AccountProvider account, bool isDark) {
    final user = account.user;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 12),
        Center(
          child: CircleAvatar(
            radius: 38,
            backgroundColor: Colors.blueAccent.withValues(alpha: 0.15),
            child: Text(
              (user?.displayName.isNotEmpty == true
                      ? user!.displayName.trim().substring(0, 1)
                      : 'S')
                  .toUpperCase(),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            user?.displayName.isNotEmpty == true
                ? user!.displayName
                : user?.email ?? '',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            user?.email ?? '',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D30) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
            ),
          ),
          child: Column(
            children: [
              _row(
                t('account.settingsSync'),
                account.lastSyncAt == null
                    ? t('account.notSyncedYet')
                    : t('account.enabled'),
                isDark,
              ),
              const Divider(height: 20),
              _row(t('account.idLabel'), user?.id ?? '-', isDark),
              if (account.error != null) ...[
                const Divider(height: 20),
                Text(
                  account.error!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            onPressed: () async {
              final ok = await account.syncNow();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? t('account.syncedFromCloud')
                        : (account.error ?? t('account.syncFailed')),
                  ),
                  backgroundColor: ok ? Colors.green : Colors.redAccent,
                ),
              );
            },
            icon: const Icon(Icons.sync, size: 18),
            label: Text(t('account.syncNow')),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            onPressed: () async {
              await account.signOut();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t('account.signedOut'))),
              );
            },
            icon: const Icon(Icons.logout, size: 18),
            label: Text(t('account.signOut')),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, bool isDark) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 注册 / 登录表单
  // ---------------------------------------------------------------------------

  Widget _buildAuthForm(AccountProvider account, bool isDark) {
    if (!account.isConfigured) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dns_outlined,
                size: 48,
                color: isDark ? Colors.white24 : Colors.black26,
              ),
              const SizedBox(height: 12),
              Text(
                t('account.backendNotConfigured'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t('account.backendHint'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Icon(Icons.code, size: 48, color: Colors.blueAccent),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _registerMode
                  ? t('account.createTitle')
                  : t('account.loginTitle'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              t('account.subtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (_registerMode) ...[
            TextFormField(
              controller: _nameController,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: t('account.displayName'),
                prefixIcon: const Icon(Icons.person_outline),
                border: const OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return t('account.nameRequired');
                }
                if (v.trim().length > 24) return t('account.nameTooLong');
                return null;
              },
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            controller: _emailController,
            enabled: !_submitting,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: t('account.email'),
              prefixIcon: const Icon(Icons.mail_outline),
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              final value = v?.trim() ?? '';
              if (value.isEmpty) return t('account.emailRequired');
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
                return t('account.emailInvalid');
              }
              return null;
            },
          ),
          if (_registerMode) ...[
            TextFormField(
              controller: _phoneController,
              enabled: !_submitting,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: t('account.phone'),
                prefixIcon: const Icon(Icons.phone_iphone),
                border: const OutlineInputBorder(),
              ),
              validator: (v) {
                if (!_registerMode) return null;
                final value = v?.trim() ?? '';
                if (value.isEmpty) return t('account.phoneRequired');
                if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(value)) {
                  return t('account.phoneInvalid');
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _smsController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('account.smsCode'),
                      prefixIcon: const Icon(Icons.sms_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (!_registerMode) return null;
                      if (v == null || v.trim().isEmpty) {
                        return t('account.smsRequired');
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: (_submitting || _sendingSms || _smsCountdown > 0)
                        ? null
                        : _sendSms,
                    child: Text(
                      _smsCountdown > 0
                          ? '${_smsCountdown}s'
                          : t('account.getSmsCode'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            controller: _passwordController,
            enabled: !_submitting,
            obscureText: true,
            decoration: InputDecoration(
              labelText: t('account.password'),
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return t('account.passwordRequired');
              if (v.length < 8) return t('account.passwordTooShort');
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
          if (_localError != null) ...[
            const SizedBox(height: 12),
            Text(
              _localError!,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: 20),

          // 合规：注册 / 登录前必须勾选同意《用户协议》与《隐私政策》
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 32,
                child: Checkbox(
                  value: _policyAgreed,
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() {
                            _policyAgreed = v ?? false;
                            if (_policyAgreed) _localError = null;
                          }),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 0,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${t('policy.loginConsentPrefix')} ',
                        style: const TextStyle(fontSize: 12),
                      ),
                      InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PolicyScreen(initialTab: 0),
                          ),
                        ),
                        child: Text(
                          t('policy.userAgreementLink'),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      Text(t('policy.and'), style: const TextStyle(fontSize: 12)),
                      InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PolicyScreen(initialTab: 1),
                          ),
                        ),
                        child: Text(
                          t('policy.privacyPolicyLink'),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _registerMode
                          ? t('account.registerAndLogin')
                          : t('account.login'),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _submitting
                ? null
                : () => setState(() {
                      _registerMode = !_registerMode;
                      _localError = null;
                    }),
            child: Text(
              _registerMode
                  ? t('account.hasAccountLogin')
                  : t('account.noAccountRegister'),
            ),
          ),
        ],
      ),
    );
  }
}
