import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/credits.dart';
import '../providers/account_provider.dart';
import 'wechat_pay_qr_dialog.dart';

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
  String _cycleId = 'month';

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

  String _effectiveCycleId(AccountProvider account) {
    final cycles = account.billing.cycles;
    if (cycles.isEmpty) return 'month';
    return cycles.any((c) => c.id == _cycleId) ? _cycleId : cycles.first.id;
  }

  MembershipCycle _cycleFor(AccountProvider account) {
    final cycles = account.billing.cycles;
    if (cycles.isEmpty) {
      return const MembershipCycle(id: 'month', name: '月付');
    }
    final id = _effectiveCycleId(account);
    return cycles.firstWhere((c) => c.id == id, orElse: () => cycles.first);
  }

  String _membershipLabel(AccountProvider account) {
    final m = account.user?.membership;
    if (m == null || !m.active) return '当前档位：Personal（免费）';
    final exp = m.expiresAt;
    final expText = exp == null
        ? ''
        : ' · ${exp.year}-${exp.month.toString().padLeft(2, '0')}-'
            '${exp.day.toString().padLeft(2, '0')} 到期';
    return '当前档位：${m.planName}$expText';
  }

  void _buyMembership(
    AccountProvider account,
    MembershipPlan plan,
    MembershipCycle cycle,
  ) {
    if (plan.free) {
      _toast('当前为免费档位，无需购买', ok: false);
      return;
    }
    if (!account.billing.wechatPay.enabled) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('微信支付暂不可用'),
          content: const Text(
            '管理员尚未完成微信支付配置。你可以先使用激活码充值，'
            '或稍后再试。',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    showWechatPayQrDialog(context, plan: plan, cycle: cycle);
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
                    const SizedBox(height: 3),
                    Text(
                      _membershipLabel(account),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? const Color(0xFF8AB4F8)
                            : const Color(0xFF0175C2),
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

        // 会员套餐
        Row(
          children: [
            const Text(
              '会员套餐',
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
        const SizedBox(height: 2),
        if (account.billing.plans.isEmpty)
          Text(
            '套餐信息加载中…',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          )
        else ...[
          if (account.billing.cycles.isNotEmpty) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final cycle in account.billing.cycles)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          cycle.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _effectiveCycleId(account) == cycle.id,
                        onSelected: (_) =>
                            setState(() => _cycleId = cycle.id),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final plan in account.billing.plans)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _MembershipCard(
                      plan: plan,
                      cycle: _cycleFor(account),
                      isDark: isDark,
                      onTap: () => _buyMembership(
                        account,
                        plan,
                        _cycleFor(account),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!account.billing.wechatPay.enabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '微信支付暂不可用：可先使用激活码充值',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.orange.shade200 : Colors.orange.shade800,
                ),
              ),
            ),
        ],
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

class _MembershipCard extends StatelessWidget {
  const _MembershipCard({
    required this.plan,
    required this.cycle,
    required this.isDark,
    required this.onTap,
  });

  final MembershipPlan plan;
  final MembershipCycle cycle;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final price = plan.priceFor(cycle.id);
    final priceText = price == price.roundToDouble()
        ? price.toStringAsFixed(0)
        : price.toStringAsFixed(2);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 156,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2C) : Colors.white,
          borderRadius: BorderRadius.circular(14),
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
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
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
            const SizedBox(height: 8),
            Text(
              plan.free ? '免费' : '¥$priceText',
              style: TextStyle(
                fontSize: plan.free ? 18 : 20,
                fontWeight: FontWeight.bold,
                color: plan.free
                    ? (isDark ? Colors.white70 : Colors.black87)
                    : const Color(0xFF07C160),
              ),
            ),
            Text(
              plan.free ? '基础功能' : '${cycle.name} · ${cycle.months} 个月',
              style: TextStyle(
                fontSize: 10,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              plan.monthlyCredits > 0
                  ? '每月 ${plan.monthlyCredits} 积分'
                  : '每月不发放积分',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '每日签到 ${plan.checkinReward} 积分',
              style: TextStyle(
                fontSize: 10,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
            if (plan.description.isNotEmpty) ...[
              const SizedBox(height: 6),
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
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  backgroundColor: const Color(0xFF07C160),
                ),
                child: Text(plan.free ? '当前免费' : '微信支付'),
              ),
            ),
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
