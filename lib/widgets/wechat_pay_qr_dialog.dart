import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/credits.dart';
import '../providers/account_provider.dart';

/// 打开微信扫码支付弹窗
Future<void> showWechatPayQrDialog(
  BuildContext context, {
  required MembershipPlan plan,
  required MembershipCycle cycle,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => WechatPayQrDialog(plan: plan, cycle: cycle),
  );
}

/// 微信支付二维码弹窗
///
/// App 内无法直接唤起微信 JSAPI，因此展示服务端支付页链接的二维码：
/// 用户截图后在微信「扫一扫 → 相册」识别，即可在微信内完成支付。
class WechatPayQrDialog extends StatefulWidget {
  const WechatPayQrDialog({
    super.key,
    required this.plan,
    required this.cycle,
  });

  final MembershipPlan plan;
  final MembershipCycle cycle;

  @override
  State<WechatPayQrDialog> createState() => _WechatPayQrDialogState();
}

class _WechatPayQrDialogState extends State<WechatPayQrDialog> {
  Timer? _pollTimer;
  DateTime? _deadline;

  bool _creating = true;
  bool _checking = false;
  bool _paid = false;
  String? _error;
  String _payUrl = '';
  WechatOrder? _order;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final account = context.read<AccountProvider>();
      final result = await account.createWechatOrder(
        planId: widget.plan.id,
        cycleId: widget.cycle.id,
      );
      if (!mounted) return;
      setState(() {
        _creating = false;
        _order = result.order;
        _payUrl = result.payUrl;
        _deadline = DateTime.now().add(const Duration(minutes: 5));
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = '$e';
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      _checkOrder(silent: true);
    });
  }

  Future<void> _checkOrder({bool silent = false}) async {
    final order = _order;
    if (order == null || _checking || _paid) return;
    if (_deadline != null && DateTime.now().isAfter(_deadline!)) {
      _pollTimer?.cancel();
      if (mounted) {
        setState(() => _error = '二维码已过期，请重新下单');
      }
      return;
    }
    if (!silent) setState(() => _checking = true);
    try {
      final account = context.read<AccountProvider>();
      final result = await account.queryWechatOrder(order.outTradeNo);
      if (!mounted) return;
      if (result.paid) {
        _pollTimer?.cancel();
        setState(() {
          _checking = false;
          _paid = true;
          _order = result.order;
        });
        await account.refreshCredits();
        await account.refreshCreditLogs();
        await account.refreshUserInfo();
        return;
      }
      setState(() {
        _checking = false;
        _order = result.order;
      });
      if (result.order.isClosed) {
        _pollTimer?.cancel();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('查询支付状态失败：$e')),
        );
      }
    }
  }

  void _copyLink() {
    if (_payUrl.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _payUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('支付链接已复制，可在微信中打开')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final price = widget.plan.priceFor(widget.cycle.id);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.wechat, color: Color(0xFF07C160), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '微信支付 · ${widget.plan.name} ${widget.cycle.name}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '¥${price == price.roundToDouble() ? price.toStringAsFixed(0) : price.toStringAsFixed(2)}'
              ' · ${widget.cycle.months} 个月',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF07C160),
              ),
            ),
            if (widget.plan.monthlyCredits > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '每月发放 ${widget.plan.monthlyCredits} 积分',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (_paid)
              _buildPaidState(isDark)
            else if (_creating)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 56),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              _buildErrorState(isDark)
            else
              _buildQrState(isDark),
            const SizedBox(height: 14),
            if (!_paid && _error == null && !_creating)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copyLink,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('复制链接'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _checking ? null : () => _checkOrder(),
                      icon: _checking
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('我已完成支付'),
                    ),
                  ),
                ],
              ),
            if (_paid)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrState(bool isDark) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E6EB)),
          ),
          child: QrImageView(
            data: _payUrl,
            size: 210,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Color(0xFF1F2329),
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Color(0xFF1F2329),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2A2A2C) : const Color(0xFFF5F8FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '支付步骤',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '① 截图保存上方二维码\n'
                '② 打开微信「扫一扫」\n'
                '③ 点右上角相册，选择刚保存的截图\n'
                '④ 在微信内完成支付，本页会自动到账',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sync, size: 13, color: isDark ? Colors.white38 : Colors.black45),
            const SizedBox(width: 4),
            Text(
              '等待支付结果…（约 5 分钟内有效）',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: Colors.orange, size: 38),
          const SizedBox(height: 10),
          Text(
            _error ?? '下单失败',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _createOrder,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildPaidState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF07C160), size: 54),
          const SizedBox(height: 12),
          const Text(
            '支付成功',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            '${_order?.planName ?? widget.plan.name} · ${_order?.cycleName ?? widget.cycle.name} 已开通，积分已到账',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}
