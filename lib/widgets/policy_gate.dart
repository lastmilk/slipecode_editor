import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/policy_service.dart';
import '../screens/policy_screen.dart';

/// 政策合规门禁（首屏）
///
/// 启动时检查用户是否已同意最新版《用户协议》与《隐私政策》：
/// - 已同意 → 正常进入；
/// - 未同意 / 版本更新 → 弹出政策确认对话框；
///   * 「同意并继续」→ 记录同意的版本号与时间；
///   * 「不同意」→ 进入受限模式（仅本地编辑可用，
///     云端构建 / AI 助手 / 账号登录等联网功能被禁用），
///     下次启动仍会提示。
///
/// 政策内容由后台「政策合规」界面发布（GET /api/policies），
/// 更新后版本号递增，所有用户会重新收到确认弹窗。
class PolicyGate extends StatefulWidget {
  const PolicyGate({super.key, required this.child});

  final Widget child;

  @override
  State<PolicyGate> createState() => _PolicyGateState();
}

class _PolicyGateState extends State<PolicyGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final sp = context.read<SettingsProvider>();
    if (!sp.isLoaded) {
      // 理论上 main() 已在 runApp 前完成 load；保险起见再等一帧
      await sp.load();
    }
    final accepted = sp.settings.policyAcceptedVersion;
    if (accepted.isEmpty) {
      // 未同意过（或曾拒绝）→ 拉取最新政策并弹窗。
      // 注意：政策正文只是「查看」入口，是否加载成功不能阻止用户同意。
      // 网络异常时使用空 bundle（仅展示政策链接）继续弹窗。
      final bundle = await PolicyService.instance.fetchPolicies();
      if (!mounted) return;
      await _showPolicyDialog(bundle ?? _emptyBundle);
    }
    if (mounted) setState(() => _checked = true);
  }

  /// 在网络不可用时的兜底：不包含正文，只有标题与政策链接
  static const PolicyBundle _emptyBundle = PolicyBundle(
    userAgreement: PolicyDocument(
      title: '',
      content: '',
      version: '',
      updatedAt: '',
    ),
    privacyPolicy: PolicyDocument(
      title: '',
      content: '',
      version: '',
      updatedAt: '',
    ),
  );

  Future<void> _showPolicyDialog(PolicyBundle bundle) async {
    final sp = context.read<SettingsProvider>();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PolicyConsentDialog(
        bundle: bundle,
        onAccept: () async {
          await sp.acceptPolicies(bundle.latestVersion);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accepted =
        context.watch<SettingsProvider>().settings.policyAcceptedVersion;
    final restricted = _checked && accepted.isEmpty;

    // 受限模式：顶部常驻提示条（点击可重新查看政策并同意）
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (restricted)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Material(
                color: Colors.orange.shade700,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PolicyScreen()),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 15,
                            color: Colors.white),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            t('policy.restrictedBanner'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 16, color: Colors.white70),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 政策确认对话框
class PolicyConsentDialog extends StatefulWidget {
  const PolicyConsentDialog({
    super.key,
    required this.bundle,
    required this.onAccept,
  });

  final PolicyBundle bundle;
  final Future<void> Function() onAccept;

  @override
  State<PolicyConsentDialog> createState() => _PolicyConsentDialogState();
}

class _PolicyConsentDialogState extends State<PolicyConsentDialog> {
  bool _accepting = false;

  Future<void> _accept() async {
    setState(() => _accepting = true);
    try {
      await widget.onAccept();
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _openPolicy(int tabIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PolicyScreen(initialTab: tabIndex)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(t('policy.dialogTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('policy.dialogBody')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              children: [
                InkWell(
                  onTap: () => _openPolicy(0),
                  child: Text(
                    t('policy.userAgreementLink'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                      fontSize: 13,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _openPolicy(1),
                  child: Text(
                    t('policy.privacyPolicyLink'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            // 不同意 → 受限模式（关闭弹窗，下次启动仍会提示）
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('policy.decline')),
          ),
          FilledButton(
            onPressed: _accepting ? null : _accept,
            child: _accepting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t('policy.accept')),
          ),
        ],
      ),
    );
  }
}
