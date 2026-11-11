import 'package:flutter/material.dart';

import '../widgets/credits_sheet.dart';

/// 升级套餐 / 充值页面（从「我的」进入，不再放在偏好设置中）
class RechargeScreen extends StatelessWidget {
  const RechargeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '升级套餐',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 28),
        child: CreditsPanel(),
      ),
    );
  }
}
