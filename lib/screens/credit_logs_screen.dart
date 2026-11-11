import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/credits.dart';
import '../providers/account_provider.dart';
import 'recharge_screen.dart';

/// 积分流水：余额概览 + 全部积分变动记录
class CreditLogsScreen extends StatefulWidget {
  const CreditLogsScreen({super.key});

  @override
  State<CreditLogsScreen> createState() => _CreditLogsScreenState();
}

class _CreditLogsScreenState extends State<CreditLogsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = context.read<AccountProvider>();
      account.refreshCredits();
      account.refreshCreditLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logs = account.creditLogs;
    final membership = account.user?.membership;
    final planName =
        (membership?.active ?? false) ? membership!.planName : '免费版';

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '积分流水',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: account.refreshCreditLogs,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await account.refreshCredits();
          await account.refreshCreditLogs();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [const Color(0xFF2B3A55), const Color(0xFF1F2A3D)]
                      : [const Color(0xFFE8F0FE), const Color(0xFFF5F8FF)],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const Icon(Icons.savings_rounded,
                      size: 34, color: Colors.amber),
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
                          '可用积分 · 当前套餐 $planName',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white54 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RechargeScreen(),
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF07C160),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                    ),
                    child: const Text('充值', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 80),
                child: Column(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 46,
                      color: isDark ? Colors.white24 : Colors.black26,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '暂无积分记录',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < logs.length; i++)
                      _LogTile(
                        entry: logs[i],
                        isDark: isDark,
                        showDivider: i != logs.length - 1,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({
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
    String two(int v) => v.toString().padLeft(2, '0');
    final timeText = time == null
        ? ''
        : '${time.year}-${two(time.month)}-${two(time.day)} '
            '${two(time.hour)}:${two(time.minute)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
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
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  timeText.isEmpty
                      ? entry.typeLabel
                      : '$timeText · ${entry.typeLabel}',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
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
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: positive ? Colors.green : Colors.orange,
                ),
              ),
              Text(
                '余额 ${entry.balance}',
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
