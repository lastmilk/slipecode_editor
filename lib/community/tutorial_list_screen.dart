import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../services/tutorial_service.dart';
import 'community_theme.dart';
import 'tutorial_lesson_screen.dart';

/// 教程列表：APP 基础 / Flutter 基础
class TutorialListScreen extends StatefulWidget {
  const TutorialListScreen({super.key, this.embedded = false});

  /// 内嵌到社区 Tab 时不显示独立 Scaffold / AppBar
  final bool embedded;

  @override
  State<TutorialListScreen> createState() => _TutorialListScreenState();
}

class _TutorialListScreenState extends State<TutorialListScreen> {
  TutorialManifest? _manifest;
  Map<String, int> _progress = {};
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
      final manifest = await TutorialService.instance.fetchManifest(
        force: true,
      );
      final progress = await TutorialService.instance.loadProgress();
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _progress = progress;
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
    if (widget.embedded) {
      return _buildBody();
    }
    return CommunityTheme.wrap(
      context,
      Scaffold(
        backgroundColor: CommunityTheme.bg,
        appBar: AppBar(
          backgroundColor: CommunityTheme.card,
          elevation: 0,
          title: Text(
            '开发快速教学',
            style: TextStyle(fontSize: 16, color: CommunityTheme.textPrimary),
          ),
          iconTheme: IconThemeData(color: CommunityTheme.textPrimary),
          actions: [
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TEmpty(emptyText: _error),
            const SizedBox(height: 8),
            TButton(
              child: const Text('重试'),
              variant: TButtonVariant.outline,
              size: TButtonSize.small,
              onPressed: _load,
            ),
          ],
        ),
      );
    }
    final manifest = _manifest;
    if (manifest == null || manifest.tracks.isEmpty) {
      return const Center(child: TEmpty(emptyText: '教程内容正在准备中'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final track in manifest.tracks) ...[
          _trackHeader(track),
          const SizedBox(height: 8),
          for (final lesson in track.lessons) _lessonCard(lesson),
          const SizedBox(height: 18),
        ],
      ],
    );
  }

  Widget _trackHeader(TutorialTrack track) {
    final done = track.lessons.where((l) => (_progress[l.id] ?? 0) > 0).length;
    final percent = track.lessons.isEmpty ? 0.0 : done / track.lessons.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0052D9), Color(0xFF366EF4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  track.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                '$done/${track.lessons.length}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          if (track.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              track.description,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Colors.white70,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 5,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lessonCard(TutorialLessonMeta lesson) {
    final step = _progress[lesson.id] ?? 0;
    final finished = lesson.stepCount > 0 && step >= lesson.stepCount;
    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TutorialLessonScreen(lessonId: lesson.id),
          ),
        );
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CommunityTheme.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: CommunityTheme.border),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: finished
                    ? const Color(0xFF00A870)
                    : CommunityTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: finished
                  ? const Icon(Icons.check, size: 18, color: Colors.white)
                  : Text(
                      '${lesson.order}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: CommunityTheme.brand,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lesson.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (lesson.summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      lesson.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: CommunityTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (lesson.durationMin > 0)
                        Text(
                          '${lesson.durationMin} 分钟',
                          style: TextStyle(
                            fontSize: 10,
                            color: CommunityTheme.textSecondary,
                          ),
                        ),
                      if (lesson.assets.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Icon(
                          Icons.folder_zip_outlined,
                          size: 12,
                          color: CommunityTheme.textSecondary,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '含资源',
                          style: TextStyle(
                            fontSize: 10,
                            color: CommunityTheme.textSecondary,
                          ),
                        ),
                      ],
                      if (step > 0 && !finished) ...[
                        const SizedBox(width: 10),
                        Text(
                          '进行中',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFFED7B2F),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: CommunityTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
