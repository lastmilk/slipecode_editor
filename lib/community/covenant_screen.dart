import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/community_service.dart';
import 'community_theme.dart';

/// 社区公约
class CovenantScreen extends StatefulWidget {
  const CovenantScreen({super.key});

  @override
  State<CovenantScreen> createState() => _CovenantScreenState();
}

class _CovenantScreenState extends State<CovenantScreen> {
  String _content = '';
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final text = await CommunityService.instance.fetchCovenant();
      if (!mounted) return;
      setState(() {
        _content = text;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
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
          title: const Text('社区公约', style: TextStyle(fontSize: 16, color: CommunityTheme.textPrimary)),
          iconTheme: const IconThemeData(color: CommunityTheme.textPrimary),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 10),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  )
                : Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: CommunityTheme.border),
                    ),
                    child: Markdown(
                      data: _content,
                      selectable: true,
                      padding: EdgeInsets.zero,
                      styleSheet: MarkdownStyleSheet(
                        h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        h2: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, height: 2),
                        h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        p: const TextStyle(fontSize: 13, height: 1.7),
                        listBullet: const TextStyle(fontSize: 13, height: 1.7),
                        tableBorder: TableBorder.all(color: CommunityTheme.border),
                        tableCellsPadding: const EdgeInsets.all(6),
                        tableHead: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        tableBody: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
      ),
    );
  }
}
