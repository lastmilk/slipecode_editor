import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/account_provider.dart';
import '../services/account_service.dart';

/// 登录设备管理：查看当前账号登录过的设备，并可将其移出登录
class LoginDevicesScreen extends StatefulWidget {
  const LoginDevicesScreen({super.key});

  @override
  State<LoginDevicesScreen> createState() => _LoginDevicesScreenState();
}

class _LoginDevicesScreenState extends State<LoginDevicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AccountProvider>().refreshDevices();
    });
  }

  Future<void> _revoke(LoginDevice device) async {
    final account = context.read<AccountProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出登录'),
        content: Text(
          '确定将「${device.name}」移出登录吗？\n该设备需要重新登录才能继续使用账号。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final (success, message) = await account.revokeDevice(device.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final devices = account.devices;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF4F5F7),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '登录设备管理',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: account.refreshDevices,
        child: account.loadingDevices && devices.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : devices.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 140),
                      Icon(
                        Icons.devices_other_rounded,
                        size: 46,
                        color: isDark ? Colors.white24 : Colors.black26,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        account.error ?? '暂无登录设备记录',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    itemCount: devices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      return _DeviceCard(
                        device: device,
                        isDark: isDark,
                        onRevoke: device.current ? null : () => _revoke(device),
                      );
                    },
                  ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.isDark,
    this.onRevoke,
  });

  final LoginDevice device;
  final bool isDark;
  final VoidCallback? onRevoke;

  IconData get _icon {
    switch (device.platform.toLowerCase()) {
      case 'android':
        return Icons.phone_android_rounded;
      case 'ios':
        return Icons.phone_iphone_rounded;
      case 'web':
        return Icons.computer_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_icon, size: 21, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (device.current) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '当前设备',
                          style: TextStyle(fontSize: 9, color: Colors.green),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (device.ip.isNotEmpty) device.ip,
                    if (device.lastActiveAt != null)
                      '最近活跃 ${_formatTime(device.lastActiveAt)}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                  ),
                ),
              ],
            ),
          ),
          if (onRevoke != null)
            TextButton(
              onPressed: onRevoke,
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('移出', style: TextStyle(fontSize: 12)),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '本机',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : const Color(0xFF9AA0A8),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
