import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/scene.dart';
import '../../services/scene_registry.dart';
import '../../services/scene_session_service.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import 'workspace_shell.dart';

/// 移动端断点：小于该宽度时角色卡压缩、气泡变宽。
const double _kCompactWidth = 700;

/// 强调色上的前景色：按亮度自动选黑或白。
Color _accentForeground(Color accent) =>
    accent.computeLuminance() > 0.55 ? Colors.black : Colors.white;

/// 强调色在浅色底上的文字色：压暗以保证对比度。
Color _accentText(ScenePalette palette, Color accent) {
  if (palette.isDark) return accent;
  return Color.lerp(accent, Colors.black, 0.32) ?? accent;
}

/// Chat 工作台（概念版，记忆库优先）。
///
/// 角色卡 + 模拟对话 + 记忆库管理，对话与记忆都写入本地草稿，
/// AI 回复为本地模拟，并会引用重要度最高的记忆条目。
class ChatWorkspace extends StatefulWidget {
  const ChatWorkspace({super.key, required this.selection, this.draft});

  final SceneSelection selection;
  final SceneDraft? draft;

  @override
  State<ChatWorkspace> createState() => _ChatWorkspaceState();
}

class _Memory {
  _Memory({
    required this.id,
    required this.content,
    required this.importance,
    required this.time,
  });

  final String id;
  String content;
  int importance;
  final DateTime time;

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'importance': importance,
    'time': time.toIso8601String(),
  };
}

class _ChatMessage {
  _ChatMessage({
    required this.fromUser,
    required this.text,
    required this.time,
    this.memoryRef,
  });

  final bool fromUser;
  final String text;
  final DateTime time;
  final String? memoryRef;

  Map<String, dynamic> toJson() => {
    'role': fromUser ? 'user' : 'ai',
    'text': text,
    'ts': time.toIso8601String(),
  };
}

const List<String> _replySeeds = [
  '嗯，我在听。你慢慢说，不着急。',
  '这件事我记下了。下次你提起时，我会先想起今天。',
  '如果是我，大概会先把窗关上，泡一杯茶，再继续想。',
  '你说的这些，和记忆里的某一段有点像，但又不太一样。',
];

class _ChatWorkspaceState extends State<ChatWorkspace> {
  SceneDefinition? _scene;

  final TextEditingController _input = TextEditingController();
  final List<_ChatMessage> _messages = [];
  final List<_Memory> _memories = [];

  bool _replying = false;
  int _replyCursor = 0;
  Timer? _replyTimer;
  Timer? _saveTimer;
  SceneDraft? _draft;

  Color get _accent => _scene?.accent ?? const Color(0xFFF472B6);

  String get _roleName =>
      _scene?.typeById(widget.selection.typeId ?? '')?.name ?? '单角色';

  List<_Memory> get _sortedMemories => [..._memories]
    ..sort((a, b) {
      final byImportance = b.importance.compareTo(a.importance);
      if (byImportance != 0) return byImportance;
      return b.time.compareTo(a.time);
    });

  @override
  void initState() {
    super.initState();
    _scene = SceneRegistry.byId(widget.selection.sceneId);
    _restore();
    _draft = widget.draft;
    if (_draft == null) {
      unawaited(_saveNow());
    }
  }

  @override
  void dispose() {
    _replyTimer?.cancel();
    _saveTimer?.cancel();
    unawaited(_saveNow());
    _input.dispose();
    super.dispose();
  }

  void _restore() {
    final payload = widget.draft?.payload;
    if (payload == null) {
      _seedMemories();
      return;
    }

    final rawMemories = payload['memories'];
    if (rawMemories is List) {
      for (final raw in rawMemories) {
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        final content = map['content'] as String? ?? '';
        if (content.trim().isEmpty) continue;
        _memories.add(
          _Memory(
            id:
                map['id'] as String? ??
                'mem_${DateTime.now().microsecondsSinceEpoch}',
            content: content,
            importance: ((map['importance'] as num?)?.toInt() ?? 3)
                .clamp(1, 5)
                .toInt(),
            time:
                DateTime.tryParse(map['time'] as String? ?? '') ??
                DateTime.now(),
          ),
        );
      }
    }

    final rawMessages = payload['messages'];
    if (rawMessages is List) {
      for (final raw in rawMessages) {
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        final text = map['text'] as String? ?? '';
        if (text.trim().isEmpty) continue;
        final fromUser = map['role'] == 'user';
        _messages.add(
          _ChatMessage(
            fromUser: fromUser,
            text: text,
            time:
                DateTime.tryParse(map['ts'] as String? ?? '') ?? DateTime.now(),
            memoryRef: fromUser ? null : _extractMemoryRef(text),
          ),
        );
      }
    }

    if (_memories.isEmpty) {
      _seedMemories();
    }
  }

  void _seedMemories() {
    _memories.addAll([
      _Memory(
        id: 'mem_seed_1',
        content: '林深怕黑，睡觉时会留一盏小夜灯。',
        importance: 4,
        time: DateTime.now().subtract(const Duration(days: 12)),
      ),
      _Memory(
        id: 'mem_seed_2',
        content: '十二岁那年在海边捡到一只受伤的海鸥，后来它飞走了。',
        importance: 5,
        time: DateTime.now().subtract(const Duration(days: 30)),
      ),
      _Memory(
        id: 'mem_seed_3',
        content: '不喜欢香菜，但会为了不扫兴勉强吃两口。',
        importance: 2,
        time: DateTime.now().subtract(const Duration(days: 3)),
      ),
    ]);
  }

  String? _extractMemoryRef(String text) {
    const prefix = '（想起：';
    if (!text.startsWith(prefix)) return null;
    final end = text.indexOf('）');
    if (end <= prefix.length) return null;
    return text.substring(prefix.length, end);
  }

  // ---------------- 草稿 ----------------

  Map<String, dynamic> _payload() => {
    'messages': _messages.map((m) => m.toJson()).toList(),
    'memories': _memories.map((m) => m.toJson()).toList(),
  };

  Future<void> _saveNow() async {
    final payload = _payload();
    final current = _draft;
    if (current == null) {
      _draft = await SceneSessionService.instance.createDraft(
        widget.selection,
        payload: payload,
      );
    } else {
      await SceneSessionService.instance.saveDraft(
        current.copyWith(payload: payload, updatedAt: DateTime.now()),
      );
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveNow());
    });
  }

  // ---------------- 交互 ----------------

  void _toast(String message) {
    if (!mounted) return;
    final p = ScenePalette.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: SceneTokens.sceneBody(13, color: p.textPrimary),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: p.codeBackground,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _replying) return;
    _input.clear();
    setState(() {
      _messages.add(
        _ChatMessage(fromUser: true, text: text, time: DateTime.now()),
      );
      _replying = true;
    });
    _scheduleSave();

    _replyTimer?.cancel();
    _replyTimer = Timer(const Duration(milliseconds: 500), _appendReply);
  }

  void _appendReply() {
    if (!mounted) return;
    final top = _sortedMemories.isNotEmpty ? _sortedMemories.first : null;
    final lead = top == null ? '' : '（想起：${top.content}）';
    final body = _replySeeds[_replyCursor++ % _replySeeds.length];
    setState(() {
      _messages.add(
        _ChatMessage(
          fromUser: false,
          text: '$lead$body',
          time: DateTime.now(),
          memoryRef: top?.content,
        ),
      );
      _replying = false;
    });
    _scheduleSave();
  }

  Future<void> _editMemory({_Memory? memory}) async {
    final contentCtrl = TextEditingController(text: memory?.content ?? '');
    var importance = memory?.importance ?? 3;
    final p = ScenePalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < _kCompactWidth;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: p.codeBackground,
              insetPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: Text(
                memory == null ? '新增记忆' : '编辑记忆',
                style: SceneTokens.sceneTitle(16, color: p.textPrimary),
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: narrow ? double.maxFinite : 380,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: p.inputFill,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: p.glassBorder),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: TextField(
                          controller: contentCtrl,
                          minLines: 2,
                          maxLines: 4,
                          cursorColor: _accent,
                          style: SceneTokens.sceneBody(
                            13,
                            color: p.textPrimary,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: '写下角色的记忆，例如「怕黑，会留小夜灯」。',
                            hintStyle: SceneTokens.sceneBody(
                              12,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            '重要度',
                            style: SceneTokens.sceneCaption(
                              11.5,
                              color: p.textSecondary,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(dialogContext).copyWith(
                                activeTrackColor: _accent,
                                thumbColor: _accent,
                                inactiveTrackColor: p.divider,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 14,
                                ),
                              ),
                              child: Slider(
                                value: importance.toDouble(),
                                min: 1,
                                max: 5,
                                divisions: 4,
                                label: '$importance',
                                onChanged: (value) {
                                  setDialogState(
                                    () => importance = value.round(),
                                  );
                                },
                              ),
                            ),
                          ),
                          Text(
                            '$importance 星',
                            style: SceneTokens.sceneBody(
                              12,
                              color: p.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(
                    '取消',
                    style: SceneTokens.sceneBody(12.5, color: p.textSecondary),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: _accentForeground(_accent),
                  ),
                  child: const Text(
                    '保存',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    // 对话框退场动画期间 TextField 仍引用控制器，延后释放避免释放后访问
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        contentCtrl.dispose,
      ),
    );

    if (!mounted) return;
    if (saved == true) {
      final content = contentCtrl.text.trim();
      if (content.isEmpty) {
        _toast('记忆内容不能为空');
        return;
      }
      setState(() {
        if (memory == null) {
          _memories.add(
            _Memory(
              id: 'mem_${DateTime.now().microsecondsSinceEpoch}',
              content: content,
              importance: importance,
              time: DateTime.now(),
            ),
          );
        } else {
          memory.content = content;
          memory.importance = importance;
        }
      });
      _scheduleSave();
      _toast(memory == null ? '已新增记忆' : '已更新记忆');
    }
  }

  void _deleteMemory(_Memory memory) {
    setState(() => _memories.remove(memory));
    _scheduleSave();
    _toast('已删除记忆');
  }

  String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  String get _subtitle {
    final element = _scene?.elementById(widget.selection.elementId ?? '')?.name;
    return '${element ?? '未选择元素'} · 角色形态：$_roleName';
  }

  @override
  Widget build(BuildContext context) {
    return WorkspaceShell(
      title: 'Chat',
      subtitle: _subtitle,
      accent: _accent,
      symbol: SceneSymbolKind.chat,
      statusLabel: '${_memories.length} 条记忆',
      leftPanel: _buildMemoryPanel(),
      rightPanel: _buildStrategyPanel(),
      body: _buildChatArea(),
    );
  }

  // ---------------- 左侧：角色卡 + 记忆库 ----------------

  Widget _buildMemoryPanel() {
    final p = ScenePalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < _kCompactWidth;
    return ListView(
      padding: const EdgeInsets.only(right: 2),
      children: [
        _buildCharacterCard(palette: p, narrow: narrow),
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              '记忆库',
              style: SceneTokens.sceneTitle(16, color: p.textPrimary),
            ),
            const Spacer(),
            InkWell(
              onTap: () => _editMemory(),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _accent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 12, color: _accent),
                    const SizedBox(width: 3),
                    Text(
                      '新增记忆',
                      style: SceneTokens.sceneCaption(
                        10.5,
                        color: _accentText(p, _accent),
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final memory in _sortedMemories) ...[
          _MemoryTile(
            memory: memory,
            accent: _accent,
            timeLabel: _formatTime(memory.time),
            onEdit: () => _editMemory(memory: memory),
            onDelete: () => _deleteMemory(memory),
          ),
          const SizedBox(height: 8),
        ],
        if (_memories.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: p.glassDecoration(radius: SceneTokens.radiusSmall),
            child: Text(
              '还没有记忆。新增一条，角色会记住它。',
              style: SceneTokens.sceneCaption(11.5, color: p.textTertiary),
            ),
          ),
      ],
    );
  }

  Widget _buildCharacterCard({
    required ScenePalette palette,
    required bool narrow,
  }) {
    if (narrow) {
      // 窄屏压缩为一行：头像 + 名字 + 形态 badge，点击展开完整设定。
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showCharacterDetail(palette),
          borderRadius: BorderRadius.circular(SceneTokens.radiusSmall),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: palette.glassDecoration(
              accent: _accent,
              radius: SceneTokens.radiusSmall,
              glow: true,
            ),
            child: Row(
              children: [
                _buildAvatar(40, 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '林深',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SceneTokens.sceneBody(
                            14,
                            color: palette.textPrimary,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildRoleBadge(palette),
                    ],
                  ),
                ),
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: palette.glassDecoration(
        accent: _accent,
        radius: SceneTokens.radiusSmall,
        glow: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildAvatar(44, 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '林深',
                      style: SceneTokens.sceneBody(
                        15,
                        color: palette.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildRoleBadge(palette),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '沉默寡言的旧书编辑，记得所有被认真说过的话。',
            style: SceneTokens.sceneCaption(11.5, color: palette.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(double size, double fontSize) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.9),
            _accent.withValues(alpha: 0.35),
          ],
        ),
        shape: BoxShape.circle,
      ),
      child: Text(
        '林',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: _accentForeground(_accent),
        ),
      ),
    );
  }

  Widget _buildRoleBadge(ScenePalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        _roleName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: SceneTokens.sceneCaption(
          9.5,
          color: _accentText(palette, _accent),
          weight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 窄屏下展开完整角色设定。
  void _showCharacterDetail(ScenePalette palette) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          decoration: BoxDecoration(
            color: palette.bgTop,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildAvatar(48, 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '林深',
                              style: SceneTokens.sceneTitle(
                                18,
                                color: palette.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _buildRoleBadge(palette),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '角色设定',
                    style: SceneTokens.sceneCaption(
                      12,
                      color: palette.textSecondary,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '沉默寡言的旧书编辑，记得所有被认真说过的话。',
                    style: SceneTokens.sceneBody(
                      13,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '记忆库共 ${_memories.length} 条记忆，重要度 ≥ 4 的条目会优先参与回复引用。',
                    style: SceneTokens.sceneCaption(
                      11.5,
                      color: palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------- 主区：对话 ----------------

  Widget _buildChatArea() {
    final p = ScenePalette.of(context);
    // 移动端避让软键盘，输入框保持可见。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.only(right: 2, bottom: 4),
                    itemCount: _messages.length + (_replying ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _messages.length) {
                        return const _ReplyingBubble();
                      }
                      return _MessageBubble(
                        message: _messages[index],
                        accent: _accent,
                        timeLabel: _formatTime(_messages[index].time),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            decoration: BoxDecoration(
              color: p.inputFill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.glassBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 3,
                    cursorColor: _accent,
                    style: SceneTokens.sceneBody(13.5, color: p.textPrimary),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      hintText: '对林深说点什么…',
                      hintStyle: SceneTokens.sceneBody(
                        12.5,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  height: 42,
                  child: FilledButton.icon(
                    onPressed: _replying ? null : _send,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: _accentForeground(_accent),
                      disabledBackgroundColor: _accent.withValues(alpha: 0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.send_rounded, size: 15),
                    label: const Text(
                      '发送',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final p = ScenePalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAvatar(62, 24),
            const SizedBox(height: 16),
            Text(
              '林深：今晚的雨像是要把整座城洗一遍。\n你想从哪里开始聊？',
              textAlign: TextAlign.center,
              style: SceneTokens.sceneBody(14, color: p.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              '概念版：回复由本地预设生成，不调用真实模型。',
              style: SceneTokens.sceneCaption(11, color: p.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 右侧：记忆策略 ----------------

  Widget _buildStrategyPanel() {
    final p = ScenePalette.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkspaceSection(
            title: '记忆策略',
            accent: _accent,
            child: Column(
              children: [
                _StrategyRow(
                  icon: Icons.bolt_outlined,
                  title: '短期记忆',
                  description: '最近 10 轮对话留在上下文中，不单独写入草稿。',
                  accent: _accent,
                ),
                const SizedBox(height: 14),
                _StrategyRow(
                  icon: Icons.inventory_2_outlined,
                  title: '长期记忆',
                  description: '重要度 ≥ 4 的条目优先参与回复引用。',
                  accent: _accent,
                ),
                const SizedBox(height: 14),
                _StrategyRow(
                  icon: Icons.star_outline_rounded,
                  title: '重要度规则',
                  description: '1-2 细节 · 3 偏好 · 4 关键经历 · 5 身份与底线。',
                  accent: _accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          WorkspaceSection(
            title: '概念版说明',
            accent: _accent,
            child: Text(
              '对话与记忆仅保存在本地草稿（scene_drafts），重启后自动恢复。\n'
              '模拟回复不会调用真实模型，也不会联网。',
              style: SceneTokens.sceneCaption(11.5, color: p.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 消息气泡 ----------------

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.accent,
    required this.timeLabel,
  });

  final _ChatMessage message;
  final Color accent;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    final mine = message.fromUser;
    final bubble = Container(
      // 气泡最大宽度为屏幕的 78%。
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.78,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? accent.withValues(alpha: 0.16) : p.glassFillStrong,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(mine ? 14 : 4),
          bottomRight: Radius.circular(mine ? 4 : 14),
        ),
        border: Border.all(
          color: mine ? accent.withValues(alpha: 0.3) : p.glassBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.text,
            style: SceneTokens.sceneBody(13, color: p.textPrimary),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                timeLabel,
                style: SceneTokens.sceneCaption(9.5, color: p.textTertiary),
              ),
              if (message.memoryRef != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '记忆引用',
                    style: SceneTokens.sceneCaption(
                      9.5,
                      color: _accentText(p, accent),
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: 0.9),
                    accent.withValues(alpha: 0.3),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Text(
                '林',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _accentForeground(accent),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _ReplyingBubble extends StatelessWidget {
  const _ReplyingBubble();

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: p.glassFillStrong,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.glassBorder),
            ),
            child: Text(
              '林深正在回忆…',
              style: SceneTokens.sceneCaption(11, color: p.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 左侧记忆条目 ----------------

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({
    required this.memory,
    required this.accent,
    required this.timeLabel,
    required this.onEdit,
    required this.onDelete,
  });

  final _Memory memory;
  final Color accent;
  final String timeLabel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 7, 9),
      decoration: BoxDecoration(
        color: p.glassFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < 5; i++)
                Icon(
                  i < memory.importance
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 11,
                  color: i < memory.importance ? accent : p.divider,
                ),
              const Spacer(),
              InkWell(
                onTap: onEdit,
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 12,
                    color: p.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 12,
                    color: p.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            memory.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: SceneTokens.sceneBody(11.5, color: p.textPrimary),
          ),
          const SizedBox(height: 5),
          Text(
            timeLabel,
            style: SceneTokens.sceneCaption(9.5, color: p.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _StrategyRow extends StatelessWidget {
  const _StrategyRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 14, color: accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: SceneTokens.sceneBody(
                  12,
                  color: p.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: SceneTokens.sceneCaption(10.5, color: p.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
