import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/credits.dart';
import '../providers/account_provider.dart';

/// 打开「积分与充值」底部弹层
Future<void> showCreditsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _CreditsSheet(),
  );
}

class _CreditsSheet extends StatelessWidget {
  const _CreditsSheet();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final height = MediaQuery.of(context).size.height;
    return Container(
      height: height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF7F8FA),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black26,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.savings_outlined,
                    size: 20, color: Colors.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '积分与充值',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: CreditsPanel(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 积分面板：余额 / 签到 / 激活码 / 套餐 / 流水
///
/// 可内嵌在设置页，也可放在底部弹层中复用。
class CreditsPanel extends StatefulWidget {
  const CreditsPanel({super.key});

  @override
  State<CreditsPanel> createState() => _CreditsPanelState();
}

class _CreditsPanelState extends State<CreditsPanel> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = context.read<AccountProvider>();
      if (!account.isSignedIn) return;
      account.refreshCredits();
      account.refreshCreditLogs();
      if (account.billing.plans.isEmpty) account.loadBillingPlans();
    });
  }

  Future<void> _checkin(AccountProvider account) async {
    if (_busy) return;
    setState(() => _busy = true);
    final (ok, message) = await account.checkin();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(message, ok: ok);
  }

  Future<void> _redeem(AccountProvider account) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('兑换激活码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: 'SLIPE-XXXX-XXXX-XXXX',
            prefixIcon: Icon(Icons.confirmation_number_outlined, size: 18),
          ),
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('兑换'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final (ok, message) = await account.redeemActivationCode(code);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(message, ok: ok);
  }

  void _toast(String message, {required bool ok}) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ok ? Colors.green : Colors.orange,
      ),
    );
  }

  void _buyPlan(CreditPlan plan) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('购买「${plan.name}」'),
        content: Text(
          '${plan.credits} 积分 · ¥${plan.price.toStringAsFixed(plan.price == plan.price.roundToDouble() ? 0 : 1)}\n\n'
          '${plan.description.isEmpty ? '' : '${plan.description}\n\n'}'
          '目前通过激活码充值：完成购买后会得到一个激活码，'
          '在「兑换激活码」处输入即可到账。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: plan.name));
              Navigator.of(ctx).pop();
            },
            child: const Text('复制套餐名'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              final account = context.read<AccountProvider>();
              _redeem(account);
            },
            child: const Text('去兑换'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final account = context.watch<AccountProvider>();
    final pricing = account.billing.pricing;

    if (!account.isSignedIn) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.lock_outline, size: 18, color: Colors.orange),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '登录 SLIPE 账号后即可使用内置大模型与积分充值',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 余额卡片
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isDark
                  ? [const Color(0xFF2B3A55), const Color(0xFF1F2A3D)]
                  : [const Color(0xFFE8F0FE), const Color(0xFFF5F8FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? Colors.white12 : const Color(0xFFD6E2F5),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.savings, size: 34, color: Colors.amber),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${account.credits}',
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      '可用积分 · 1 积分 ≈ ${pricing.tokensPerCredit} Tokens',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  OutlinedButton(
                    onPressed: account.checkedInToday || _busy
                        ? null
                        : () => _checkin(account),
                    child: Text(
                      account.checkedInToday
                          ? '已签到'
                          : '签到 +${pricing.checkinReward}',
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _busy ? null : () => _redeem(account),
                    child: const Text('兑换激活码'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // 套餐
        Row(
          children: [
            const Text(
              '充值套餐',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => account.loadBillingPlans(),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('刷新', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (account.billing.plans.isEmpty)
          Text(
            '套餐信息加载中…',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final plan in account.billing.plans)
                _PlanCard(
                  plan: plan,
                  isDark: isDark,
                  onTap: () => _buyPlan(plan),
                ),
            ],
          ),
        const SizedBox(height: 20),

        // 流水
        Row(
          children: [
            const Text(
              '积分流水',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => account.refreshCreditLogs(),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('刷新', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (account.creditLogs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无积分记录',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDark ? Colors.white12 : const Color(0xFFE4E7EB),
              ),
            ),
            child: Column(
              children: [
                for (var i = 0; i < account.creditLogs.length; i++)
                  _LogRow(
                    entry: account.creditLogs[i],
                    isDark: isDark,
                    showDivider: i != account.creditLogs.length - 1,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.isDark,
    required this.onTap,
  });

  final CreditPlan plan;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final price = plan.price == plan.price.roundToDouble()
        ? plan.price.toStringAsFixed(0)
        : plan.price.toStringAsFixed(1);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 152,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: plan.badge.isNotEmpty
                ? primary.withValues(alpha: 0.6)
                : (isDark ? Colors.white12 : const Color(0xFFE4E7EB)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    plan.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (plan.badge.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      plan.badge,
                      style: TextStyle(fontSize: 9, color: primary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${plan.credits} 积分',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '¥$price',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.amber,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (plan.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                plan.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.3,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.entry,
    required this.isDark,
    required this.showDivider,
  });

  final CreditLogEntry entry;
  final bool isDark;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final positive = entry.amount >= 0;
    final time = entry.time;
    final timeText = time == null
        ? ''
        : '${time.month.toString().padLeft(2, '0')}-'
            '${time.day.toString().padLeft(2, '0')} '
            '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: isDark ? Colors.white10 : const Color(0xFFEDEFF2),
                ),
              )
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.note.isEmpty ? entry.typeLabel : entry.note,
                  style: const TextStyle(fontSize: 12),
                ),
                if (timeText.isNotEmpty)
                  Text(
                    '$timeText · ${entry.typeLabel}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${positive ? '+' : ''}${entry.amount}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: positive ? Colors.green : Colors.orange,
                ),
              ),
              Text(
                '余额 ${entry.balance}',
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
