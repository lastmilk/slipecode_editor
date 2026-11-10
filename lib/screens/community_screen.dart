import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../community/community_theme.dart';
import '../community/covenant_screen.dart';
import '../community/create_post_sheet.dart';
import '../community/feed_tab.dart';
import '../community/my_tab.dart';
import '../community/payload_tab.dart';
import '../community/tutorial_list_screen.dart';

/// 社区主页：推荐 / 教程 / Payload / 我的
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _compose() async {
    final ok = await showCreatePostSheet(context);
    if (ok == true && mounted) {
      _tab.animateTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommunityTheme.wrap(
      context,
      Scaffold(
        backgroundColor: CommunityTheme.bg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          titleSpacing: 16,
          title: const Row(
            children: [
              Icon(Icons.forum_outlined, size: 20, color: CommunityTheme.brand),
              SizedBox(width: 6),
              Text(
                'SLIPE 社区',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: CommunityTheme.textPrimary),
              ),
            ],
          ),
          iconTheme: const IconThemeData(color: CommunityTheme.textPrimary),
          actions: [
            IconButton(
              tooltip: '社区公约',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CovenantScreen()),
              ),
              icon: const Icon(Icons.gavel_outlined, size: 20),
            ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(46),
            child: Container(
              color: Colors.white,
              child: TTabsBar(
                controller: _tab,
                isScrollable: true,
                tabs: const [
                  TTab(text: '推荐'),
                  TTab(text: '教程'),
                  TTab(text: 'Payload'),
                  TTab(text: '我的'),
                ],
              ),
            ),
          ),
        ),
        body: TTabsBarView(
          controller: _tab,
          children: [
            FeedTab(onCompose: _compose),
            const TutorialListScreen(embedded: true),
            const PayloadTab(),
            const MyTab(),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _compose,
          backgroundColor: CommunityTheme.brand,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('发帖'),
        ),
      ),
    );
  }
}
