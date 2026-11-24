import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/account_provider.dart';
import '../providers/ai_provider.dart';
import '../providers/settings_provider.dart';
import 'credits_sheet.dart';
import 'desktop/desktop_dialogs.dart';

/// 对话框底部的模型选择栏
///
/// 登录用户默认使用 SLIPE 内置模型（DeepSeek Flash），
/// 也可切换到设置里配置的自有模型。
class LlmModelBar extends StatelessWidget {
  const LlmModelBar({super.key, required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final account = context.watch<AccountProvider>();
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => showLlmModelSheet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2D2D30) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? Colors.white12 : const Color(0xFFE0E4E8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    ai.isUsingBuiltinModel ? Icons.auto_awesome : Icons.tune,
                    size: 13,
                    color: primary,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      ai.currentModelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.unfold_more,
                    size: 13,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ],
              ),
            ),
          ),
        ),
        const Spacer(),
        if (account.isSignedIn)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => showCreditsSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.savings_outlined,
                    size: 13,
                    color: Colors.amber,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${account.credits} 积分',
                    style: const TextStyle(fontSize: 11, color: Colors.amber),
                  ),
                ],
              ),
            ),
          )
        else
          Text(
            '未登录 · 仅可使用自定义模型',
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
      ],
    );
  }
}

/// 打开模型选择弹层（内置模型 / 自定义模型）
Future<void> showLlmModelSheet(BuildContext context) async {
  final ai = context.read<AiProvider>();
  final account = context.read<AccountProvider>();
  final settingsProvider = context.read<SettingsProvider>();
  final settings = settingsProvider.settings;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final primary = Theme.of(context).colorScheme.primary;

  if (account.isSignedIn && account.builtinModels.isEmpty) {
    await account.refreshBuiltinModels();
  }
  if (!context.mounted) return;
  final models = account.builtinModels;
  final profiles = settings.llmProfiles;

  final currentBuiltinId = settings.builtinLlmId.isEmpty
      ? account.defaultBuiltinModelId
      : settings.builtinLlmId;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: isDark ? const Color(0xFF232326) : Colors.white,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '选择模型',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
            if (account.isSignedIn) ...[
              _sheetHeader('SLIPE 内置模型', isDark),
              for (final model in models)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: primary,
                  ),
                  title: Text(model.name),
                  subtitle: Text(
                    '${model.description.isEmpty ? '由 SLIPE 提供' : model.description}'
                    ' · 倍率 ${model.multiplier}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: settings.llmUseBuiltin && model.id == currentBuiltinId
                      ? Icon(Icons.check_circle, size: 18, color: primary)
                      : null,
                  onTap: () async {
                    await ai.selectBuiltinModel(model);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                ),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text(
                    '内置模型列表加载失败，请检查网络后重试',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text(
                  '登录 SLIPE 账号后可使用内置大模型（注册赠送积分）',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            if (profiles.isNotEmpty) ...[
              _sheetHeader('自定义模型', isDark),
              for (final profile in profiles)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.tune, size: 18),
                  title: Text(profile.name),
                  subtitle: Text(
                    '${profile.model} · ${profile.apiBase}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: !settings.llmUseBuiltin &&
                          profile.id == settings.activeLlmId
                      ? Icon(Icons.check_circle, size: 18, color: primary)
                      : null,
                  onTap: () async {
                    await ai.selectCustomModel(profile);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                ),
            ],
            const Divider(height: 8),
            ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 18),
              title: const Text('管理模型与积分'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showSettingsDialog(context);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _sheetHeader(String title, bool isDark) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white54 : Colors.black54,
      ),
    ),
  );
}
