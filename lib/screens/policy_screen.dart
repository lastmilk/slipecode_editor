import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../l10n/app_localizations.dart';
import '../services/policy_service.dart';

/// 政策全文查看页（用户协议 / 隐私政策 切换）
///
/// 数据来源：后台「政策合规」界面发布的最新内容（GET /api/policies）。
class PolicyScreen extends StatefulWidget {
  const PolicyScreen({super.key, this.initialTab = 0});

  /// 0 = 用户协议，1 = 隐私政策
  final int initialTab;

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  PolicyBundle? _bundle;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bundle = await PolicyService.instance.fetchPolicies();
    if (!mounted) return;
    setState(() {
      _bundle = bundle;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('policy.dialogTitle')),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: t('policy.userAgreement')),
            Tab(text: t('policy.privacyPolicy')),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : bundle == null || !bundle.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t('policy.loadFailed')),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _load,
                        child: Text(t('common.retry')),
                      ),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _PolicyView(
                      doc: bundle.userAgreement,
                      fallbackTitle: t('policy.userAgreement'),
                    ),
                    _PolicyView(
                      doc: bundle.privacyPolicy,
                      fallbackTitle: t('policy.privacyPolicy'),
                    ),
                  ],
                ),
    );
  }
}

class _PolicyView extends StatelessWidget {
  const _PolicyView({required this.doc, required this.fallbackTitle});

  final PolicyDocument doc;
  final String fallbackTitle;

  @override
  Widget build(BuildContext context) {
    if (doc.isEmpty) {
      return Center(
        child: Text(t('policy.notPublished', {'title': fallbackTitle})),
      );
    }
    final updatedAt = doc.updatedAt.isEmpty
        ? ''
        : t('policy.updatedAt', {'date': doc.updatedAt.substring(0, 10)});
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                doc.title.isEmpty ? fallbackTitle : doc.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${t('policy.version', {'version': doc.version})}$updatedAt',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white38
                : Colors.black45,
          ),
        ),
        const Divider(height: 24),
        Markdown(
          data: doc.content,
          padding: EdgeInsets.zero,
          selectable: true,
          shrinkWrap: true,
        ),
      ],
    );
  }
}
