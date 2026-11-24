import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'app_globals.dart';

/// 桌面端 OAuth 回调输入框
///
/// 桌面系统没有移动端的深链回调，浏览器完成授权后会跳转到
/// `slipe://...` 回调地址并显示「无法打开页面」，用户复制该地址粘贴回来即可。
class DesktopOAuthPrompt {
  DesktopOAuthPrompt._();

  static Future<Uri?> ask({required String hint, String? title}) async {
    final context = appNavigatorKey.currentContext;
    if (context == null) return null;
    final controller = TextEditingController();
    try {
      final value = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(title ?? t('desktop.oauth.pasteTitle')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('desktop.oauth.pasteDesc'),
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: hint.isEmpty
                        ? t('desktop.oauth.pasteHint')
                        : hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t('common.cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: Text(t('common.confirm')),
            ),
          ],
        ),
      );
      final trimmed = (value ?? '').trim();
      if (trimmed.isEmpty) return null;
      return Uri.tryParse(trimmed);
    } finally {
      controller.dispose();
    }
  }
}
