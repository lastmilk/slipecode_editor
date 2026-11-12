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
  /// 每次加载的条数：默认只展示最近 30 条
  static const int _pageSize = 30;

  int _visibleCount = _pageSize;

  /// 收支筛选：all=全部，in=进账，out=出账
  String _flowFilter = 'all';

  /// 日期筛选（含首尾当天），null 表示不限制
  DateTimeRange? _dateRange;

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

  /// 重置分页并重建列表
  void _resetPaging() => _visibleCount = _pageSize;

  /// 按收支与日期筛选，并按时间倒序（最近在前）
  List<CreditLogEntry> _filteredLogs(List<CreditLogEntry> logs) {
    final range = _dateRange;
    final start = range == null
        ? null
        : DateTime(range.start.year, range.start.month, range.start.day);
    final end = range == null
        ? null
        : DateTime(range.end.year, range.end.month, range.end.day)
            .add(const Duration(days: 1));

    final filtered = logs.where((entry) {
      if (_flowFilter == 'in' && entry.amount < 0) return false;
      if (_flowFilter == 'out' && entry.amount >= 0) return false;
      if (start != null && end != null) {
        final time = entry.time;
        if (time == null) return false;
        if (time.isBefore(start) || !time.isBefore(end)) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final at = a.time;
      final bt = b.time;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return filtered;
  }

  /// 选择日期范围
  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020, 1, 1),
      lastDate: now,
      initialDateRange: _dateRange,
      helpText: '筛选积分流水日期',
      saveText: '确定',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateRange = picked;
      _resetPaging();
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

    final filtered = _filteredLogs(logs);
    final visible = filtered.take(_visibleCount).toList();
    final hasMore = visible.length < filtered.length;

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
            const SizedBox(height: 12),
            _buildFilterBar(isDark),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
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
                      logs.isEmpty ? '暂无积分记录' : '没有符合筛选条件的记录',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Column(
                    children: [
                      for (var i = 0; i < visible.length; i++)
                        _LogTile(
                          entry: visible[i],
                          isDark: isDark,
                          showDivider: i != visible.length - 1,
                        ),
                    ],
                  ),
                ),
              ),
              if (hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: OutlinedButton.icon(
                      onPressed: () => setState(
                        () => _visibleCount += _pageSize,
                      ),
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: Text(
                        '加载更多（剩余 ${filtered.length - visible.length} 条）',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                )
              else if (filtered.length > _pageSize)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: Text(
                      '已显示全部 ${filtered.length} 条',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white30 : Colors.black38,
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 筛选栏：全部 / 进账 / 出账 + 日期范围
  Widget _buildFilterBar(bool isDark) {
    final range = _dateRange;
    String two(int v) => v.toString().padLeft(2, '0');
    final dateLabel = range == null
        ? '日期'
        : '${two(range.start.month)}-${two(range.start.day)}'
            ' ~ ${two(range.end.month)}-${two(range.end.day)}';

    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFlowChip('all', '全部', isDark),
                const SizedBox(width: 6),
                _buildFlowChip('in', '进账', isDark),
                const SizedBox(width: 6),
                _buildFlowChip('out', '出账', isDark),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: _pickDateRange,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          icon: const Icon(Icons.date_range, size: 15),
          label: Text(dateLabel, style: const TextStyle(fontSize: 12)),
        ),
        if (range != null)
          IconButton(
            tooltip: '清除日期筛选',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => setState(() {
              _dateRange = null;
              _resetPaging();
            }),
            icon: const Icon(Icons.close, size: 16),
          ),
      ],
    );
  }

  Widget _buildFlowChip(String value, String label, bool isDark) {
    final selected = _flowFilter == value;
    final accent = const Color(0xFF0175C2);
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selectedColor: accent.withValues(alpha: isDark ? 0.3 : 0.14),
      labelStyle: TextStyle(
        color: selected
            ? (isDark ? Colors.white : accent)
            : (isDark ? Colors.white60 : Colors.black54),
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(
        color: selected
            ? accent
            : (isDark ? Colors.white24 : const Color(0xFFDDE1E6)),
      ),
      onSelected: (_) => setState(() {
        _flowFilter = value;
        _resetPaging();
      }),
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
