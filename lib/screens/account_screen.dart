import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/account_provider.dart';

/// SlipCode 独立账号页面（注册 / 登录 / 退出）
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

  bool _registerMode = false;
  bool _submitting = false;
  String? _localError;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _localError = null;
    });
    final account = context.read<AccountProvider>();
    final ok = _registerMode
        ? await account.register(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            displayName: _nameController.text.trim(),
          )
        : await account.login(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok) _localError = account.error ?? '操作失败';
    });
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_registerMode ? '注册成功，已登录' : '登录成功'),
          backgroundColor: Colors.green,
        ),
      );
      _passwordController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SlipCode 账号'),
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
                '设置同步',
                account.lastSyncAt == null
                    ? '尚未同步'
                    : '已开启',
                isDark,
              ),
              const Divider(height: 20),
              _row('账号 ID', user?.id ?? '-', isDark),
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
                  content: Text(ok ? '设置已从云端同步' : (account.error ?? '同步失败')),
                  backgroundColor: ok ? Colors.green : Colors.redAccent,
                ),
              );
            },
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('立即同步设置'),
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
                const SnackBar(content: Text('已退出 SlipCode 账号')),
              );
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('退出登录'),
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
              const Text(
                '尚未配置账号后端',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '请在 .env 中填写 ACCOUNT_BACKEND_BASE_URL\n'
                '（backend/ 目录提供了可直接部署的后端实现）',
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
              _registerMode ? '创建 SlipCode 账号' : '登录 SlipCode 账号',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '独立账号体系，与 GitHub / Gitee 无关，用于同步偏好设置',
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
              decoration: const InputDecoration(
                labelText: '昵称',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '请输入昵称';
                if (v.trim().length > 24) return '昵称不能超过 24 个字符';
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
            decoration: const InputDecoration(
              labelText: '邮箱',
              prefixIcon: Icon(Icons.mail_outline),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final value = v?.trim() ?? '';
              if (value.isEmpty) return '请输入邮箱';
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
                return '邮箱格式不正确';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _passwordController,
            enabled: !_submitting,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              prefixIcon: Icon(Icons.lock_outline),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return '请输入密码';
              if (v.length < 8) return '密码至少 8 位';
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
                  : Text(_registerMode ? '注册并登录' : '登录'),
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
            child: Text(_registerMode ? '已有账号？去登录' : '没有账号？注册一个'),
          ),
        ],
      ),
    );
  }
}
