import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import '../providers/editor_provider.dart';
import '../providers/project_provider.dart';
import '../screens/editor_screen.dart';
import '../services/tutorial_service.dart';
import 'community_theme.dart';
import 'practice_catalog.dart';
import 'practice_controller.dart';

/// 交互式课程详情
class TutorialLessonScreen extends StatefulWidget {
  const TutorialLessonScreen({super.key, required this.lessonId});

  final String lessonId;

  @override
  State<TutorialLessonScreen> createState() => _TutorialLessonScreenState();
}

class _TutorialLessonScreenState extends State<TutorialLessonScreen> {
  final _service = TutorialService.instance;

  TutorialLesson? _lesson;
  bool _loading = true;
  String _error = '';
  int _index = 0;
  int? _quizChoice;
  bool _quizChecked = false;
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloaded = {};

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
      final lesson = await _service.fetchLesson(widget.lessonId);
      final progress = await _service.progressFor(widget.lessonId);
      if (!mounted) return;
      setState(() {
        _lesson = lesson;
        _index = progress
            .clamp(0, (lesson.steps.length - 1).clamp(0, 999))
            .toInt();
        _loading = false;
      });
      _checkDownloaded(lesson);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _checkDownloaded(TutorialLesson lesson) async {
    for (final asset in lesson.assets) {
      final ok = await _service.isAssetDownloaded(lesson.id, asset.id);
      if (ok && mounted) setState(() => _downloaded.add(asset.id));
    }
  }

  Future<void> _download(TutorialAsset asset) async {
    final lesson = _lesson;
    if (lesson == null) return;
    setState(() => _downloadProgress[asset.id] = 0);
    try {
      await _service.downloadAsset(
        lesson.id,
        asset,
        onProgress: (value) {
          if (mounted) setState(() => _downloadProgress[asset.id] = value);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(asset.id);
        _downloaded.add(asset.id);
      });
      TToast.showSuccess('资源已下载并解压', context: context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadProgress.remove(asset.id));
      TToast.showFail('下载失败：$e', context: context);
    }
  }

  Future<void> _saveProgress(int step) async {
    final lesson = _lesson;
    if (lesson == null) return;
    final done = step >= lesson.steps.length;
    await _service.saveProgress(
      lesson.id,
      done ? lesson.steps.length : step + 1,
      lesson.steps.length,
    );
  }

  Future<void> _next() async {
    final lesson = _lesson;
    if (lesson == null) return;
    if (_index >= lesson.steps.length - 1) {
      await _saveProgress(lesson.steps.length);
      if (!mounted) return;
      TToast.showSuccess('课程已完成', context: context);
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index += 1;
      _quizChoice = null;
      _quizChecked = false;
    });
    await _saveProgress(_index - 1);
  }

  Future<void> _prev() async {
    if (_index == 0) return;
    setState(() {
      _index -= 1;
      _quizChoice = null;
      _quizChecked = false;
    });
    await _saveProgress(_index - 1);
  }

  /// 进入实操：创建临时练习项目、打开编辑器并显示教学模式悬浮球
  Future<void> _startPractice() async {
    final lesson = _lesson;
    if (lesson == null) return;
    final spec = PracticeSpec.forLesson(lesson);
    final controller = PracticeController.instance;
    final editor = context.read<EditorProvider>();
    try {
      await controller.start(
        context,
        spec,
        beforeCheck: () async {
          await editor.saveAll();
        },
      );
      final path = controller.projectPath;
      if (path == null || !mounted) return;
      await context.read<ProjectProvider>().openProject(path, kind: 'classic');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const EditorScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      TToast.showFail('进入实操失败：$e', context: context);
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
          iconTheme: const IconThemeData(color: CommunityTheme.textPrimary),
          title: Text(
            _lesson?.title ?? '课程',
            style: const TextStyle(fontSize: 16, color: CommunityTheme.textPrimary),
          ),
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
    final lesson = _lesson;
    if (lesson == null || lesson.steps.isEmpty) {
      return const Center(child: TEmpty(emptyText: '课程内容为空'));
    }
    final step = lesson.steps[_index];
    return Column(
      children: [
        LinearProgressIndicator(
          value: (_index + 1) / lesson.steps.length,
          minHeight: 3,
          backgroundColor: CommunityTheme.border,
          valueColor: const AlwaysStoppedAnimation(CommunityTheme.brand),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Text(
                '第 ${_index + 1} / ${lesson.steps.length} 步',
                style: const TextStyle(fontSize: 11, color: CommunityTheme.textSecondary),
              ),
              const Spacer(),
              Text(
                _stepLabel(step.type),
                style: const TextStyle(fontSize: 11, color: CommunityTheme.brand),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildStep(step),
              if (lesson.assets.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('课程资源', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final asset in lesson.assets) _buildAsset(asset),
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: CommunityTheme.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TButton(
                  child: const Text('上一步'),
                  variant: TButtonVariant.outline,
                  onPressed: _index == 0 ? null : _prev,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TButton(
                  child: Text(_index >= lesson.steps.length - 1 ? '完成课程' : '下一步'),
                  onPressed: _next,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _stepLabel(String type) {
    switch (type) {
      case 'code':
        return '代码示例';
      case 'quiz':
        return '随堂测验';
      case 'action':
        return '动手试试';
      default:
        return '知识讲解';
    }
  }

  Widget _buildStep(TutorialStep step) {
    switch (step.type) {
      case 'code':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (step.title.isNotEmpty)
              Text(step.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            if (step.body.isNotEmpty) ...[
              const SizedBox(height: 8),
              _markdown(step.body),
            ],
            const SizedBox(height: 10),
            _codeBlock(step.code),
          ],
        );
      case 'quiz':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(step.question, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.5)),
            const SizedBox(height: 10),
            for (var i = 0; i < step.options.length; i++)
              GestureDetector(
                onTap: _quizChecked ? null : () => setState(() => _quizChoice = i),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _quizChoice == i ? CommunityTheme.brand : CommunityTheme.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _quizChoice == i ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 18,
                        color: _quizChoice == i ? CommunityTheme.brand : CommunityTheme.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(step.options[i], style: const TextStyle(fontSize: 13))),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            if (!_quizChecked)
              TButton(
                child: const Text('提交答案'),
                size: TButtonSize.small,
                onPressed: _quizChoice == null
                    ? null
                    : () => setState(() => _quizChecked = true),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _quizChoice == step.answer
                      ? const Color(0xFFE8F8F2)
                      : const Color(0xFFFFF1F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _quizChoice == step.answer ? '回答正确' : '回答错误，正确答案：${step.options.isEmpty ? '' : step.options[step.answer]}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _quizChoice == step.answer
                            ? const Color(0xFF00A870)
                            : const Color(0xFFD54941),
                      ),
                    ),
                    if (step.explain.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(step.explain, style: const TextStyle(fontSize: 12, height: 1.6)),
                    ],
                  ],
                ),
              ),
          ],
        );
      case 'action':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_circle_outline, color: CommunityTheme.brand),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(step.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _markdown(step.body),
            if (_lesson?.track == 'flutter') ...[
              const SizedBox(height: 14),
              TButton(
                child: const Text('进入实操'),
                onPressed: _startPractice,
              ),
              const SizedBox(height: 6),
              const Text(
                '进入后会创建临时练习项目，并在右下角显示「教学模式」悬浮球。',
                style: TextStyle(
                  fontSize: 11,
                  color: CommunityTheme.textSecondary,
                ),
              ),
            ],
          ],
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (step.title.isNotEmpty)
              Text(step.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 10),
            _markdown(step.body),
          ],
        );
    }
  }

  Widget _markdown(String data) {
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(fontSize: 14, height: 1.75),
        h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        h3: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        code: const TextStyle(
          fontSize: 12,
          fontFamily: 'monospace',
          backgroundColor: Color(0xFFF2F3F5),
        ),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(12),
      ),
    );
  }

  Widget _codeBlock(String code) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                TToast.showSuccess('代码已复制', context: context);
              },
              icon: const Icon(Icons.copy, size: 14, color: Colors.white70),
              label: const Text('复制', style: TextStyle(fontSize: 11, color: Colors.white70)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.6,
                color: Color(0xFFE2E8F0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAsset(TutorialAsset asset) {
    final progress = _downloadProgress[asset.id];
    final downloaded = _downloaded.contains(asset.id);
    final sizeText = asset.size > 0
        ? '${(asset.size / 1024 / 1024).toStringAsFixed(1)} MB'
        : '';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CommunityTheme.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.folder_zip_outlined, size: 20, color: CommunityTheme.brand),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(asset.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    if (sizeText.isNotEmpty)
                      Text(sizeText, style: const TextStyle(fontSize: 10, color: CommunityTheme.textSecondary)),
                  ],
                ),
              ),
              if (progress != null)
                SizedBox(
                  width: 56,
                  child: LinearProgressIndicator(value: progress == 0 ? null : progress, minHeight: 4),
                )
              else
                TButton(
                  child: Text(downloaded ? '已下载' : '下载'),
                  size: TButtonSize.extraSmall,
                  variant: TButtonVariant.outline,
                  onPressed: downloaded ? null : () => _download(asset),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
