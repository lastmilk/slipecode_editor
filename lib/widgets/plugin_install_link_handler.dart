import 'dart:async';

import 'package:flutter/material.dart';

import '../models/plugin.dart';
import '../services/app_globals.dart';
import '../services/desktop_platform.dart';
import '../services/oauth_link_bus.dart';
import '../services/plugin_market_service.dart';
import '../services/plugin_service.dart';

/// 处理官网发起的 `slipe://plugin/install?ticket=...` 安装请求。
class PluginInstallLinkHandler extends StatefulWidget {
  const PluginInstallLinkHandler({super.key, required this.child});

  final Widget child;

  @override
  State<PluginInstallLinkHandler> createState() =>
      _PluginInstallLinkHandlerState();
}

class _PluginInstallLinkHandlerState extends State<PluginInstallLinkHandler> {
  StreamSubscription<Uri>? _subscription;
  final Set<String> _handledTickets = {};

  @override
  void initState() {
    super.initState();
    _subscription = OAuthLinkBus.instance.linkStream.listen(_handle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial = OAuthLinkBus.instance.lastLink;
      if (initial != null) _handle(initial);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _handle(Uri uri) {
    if (uri.scheme != 'slipe' || uri.host != 'plugin' || uri.path != '/install') {
      return;
    }
    final ticket = uri.queryParameters['ticket']?.trim() ?? '';
    if (ticket.isEmpty || !_handledTickets.add(ticket)) return;
    OAuthLinkBus.instance.consume(uri);
    unawaited(_install(ticket));
  }

  Future<void> _install(String ticket) async {
    String title = '插件安装';
    String message;
    try {
      if (!DesktopPlatform.isDesktop) {
        throw const PluginMarketException('插件安装目前需要在 SLIPE 桌面端完成。');
      }
      final manifest = await PluginMarketService.instance
          .redeemInstallTicket(ticket);
      title = '确认安装插件';
      final accepted = await _confirm(manifest);
      if (!accepted) {
        message = '已取消安装 ${manifest.name}。';
      } else {
        final installed = await PluginService.instance.install(
          manifest: manifest,
          source: 'market',
        );
        title = '安装完成';
        message = '${installed.manifest.name} 已添加到 SLIPE 插件中心。';
      }
    } catch (error) {
      message = error.toString().replaceFirst('PluginMarketException: ', '');
    }
    if (!mounted) return;
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(PluginManifest manifest) async {
    final context = appNavigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('安装 ${manifest.name}？'),
            content: Text(
              '发布者：${manifest.publisher.isEmpty ? '未知' : manifest.publisher}\n'
              '版本：${manifest.version}\n\n'
              '插件将加入本地 SLIPE 插件中心。请只安装你信任的插件。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('安装'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
