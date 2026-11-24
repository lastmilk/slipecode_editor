import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/scene.dart';
import '../../services/scene_registry.dart';
import '../../services/scene_session_service.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import 'workspace_shell.dart';

/// 窄屏断点：小于该宽度时主内容改为单列排布。
const double _kCompactWidth = 700;

/// 强调色在浅色背景上的文字色：压暗以保证对比度。
Color _accentText(ScenePalette palette, Color accent) {
  if (palette.isDark) return accent;
  return Color.lerp(accent, Colors.black, 0.32) ?? accent;
}

/// 运行成功语义色：浅色主题下改用深绿，避免浅底看不清。
Color _successColor(ScenePalette palette) =>
    palette.isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);

/// 运行失败语义色：浅色主题下改用深红。
Color _dangerColor(ScenePalette palette) =>
    palette.isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);

/// Auto 工作台（概念版）。
///
/// 展示「Dify 工作流 + 定时触发」的完整概念链路：
/// 切换预设模板、配置 Cron、计算下次运行时间、查看模拟运行记录与启用开关。
class AutoWorkspace extends StatefulWidget {
  const AutoWorkspace({super.key, required this.selection, this.draft});

  final SceneSelection selection;
  final SceneDraft? draft;

  @override
  State<AutoWorkspace> createState() => _AutoWorkspaceState();
}

class _AutoWorkspaceState extends State<AutoWorkspace> {
  SceneDefinition? _scene;
  late String _presetId;

  final TextEditingController _cronCtrl = TextEditingController(
    text: '0 9 * * *',
  );
  String? _cronError;
  DateTime? _nextRunAt;
  bool _enabled = false;

  SceneDraft? _draft;
  Timer? _cronDebounce;
  Timer? _saveTimer;

  /// 模拟运行记录（概念版本地数据）。
  late final List<_RunRecord> _records = [
    _RunRecord(
      time: DateTime.now().subtract(const Duration(hours: 8)),
      ok: true,
      duration: '12.4s',
    ),
    _RunRecord(
      time: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
      ok: true,
      duration: '9.8s',
    ),
    _RunRecord(
      time: DateTime.now().subtract(const Duration(days: 1, hours: 5)),
      ok: false,
      duration: '3.2s',
    ),
    _RunRecord(
      time: DateTime.now().subtract(const Duration(days: 2)),
      ok: true,
      duration: '11.1s',
    ),
  ];

  Color get _accent => _scene?.accent ?? const Color(0xFF38BDF8);

  @override
  void initState() {
    super.initState();
    _scene = SceneRegistry.byId(widget.selection.sceneId);
    final types = _scene?.types ?? const <SceneProjectType>[];
    final preferred = widget.selection.typeId;
    _presetId = types.any((t) => t.id == preferred)
        ? preferred!
        : (types.isNotEmpty ? types.first.id : 'blank');

    _restore();
    _draft = widget.draft;
    if (_draft == null) {
      unawaited(_saveNow());
    }
    // 首次计算下次运行时间（不再等待防抖）
    _recomputeCron();
  }

  @override
  void dispose() {
    _cronDebounce?.cancel();
    _saveTimer?.cancel();
    unawaited(_saveNow());
    _cronCtrl.dispose();
    super.dispose();
  }

  void _restore() {
    final payload = widget.draft?.payload;
    if (payload == null) return;

    final preset = payload['preset'];
    if (preset is String &&
        (_scene?.types.any((t) => t.id == preset) ?? false)) {
      _presetId = preset;
    }
    final cron = payload['cron'];
    if (cron is String && cron.trim().isNotEmpty) {
      _cronCtrl.text = cron;
    }
    final enabled = payload['enabled'];
    if (enabled is bool) {
      _enabled = enabled;
    }
  }

  // ---------------- 草稿 ----------------

  Map<String, dynamic> _payload() => {
    'preset': _presetId,
    'cron': _cronCtrl.text.trim(),
    'enabled': _enabled,
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

  // ---------------- Cron ----------------

  void _onCronChanged(String _) {
    _cronDebounce?.cancel();
    _cronDebounce = Timer(const Duration(milliseconds: 300), _recomputeCron);
    _scheduleSave();
  }

  void _recomputeCron() {
    final expr = _cronCtrl.text.trim();
    DateTime? next;
    String? error;
    if (_parseCron(expr) == null) {
      error = '表达式不合法，需 5 段：分 时 日 月 周（0-59 / 0-23 / 1-31 / 1-12 / 0-7）';
    } else {
      next = _nextRun(expr, DateTime.now());
      if (next == null) {
        error = '未来 90 天内没有可执行时间，请检查日期与月份组合';
      }
    }
    if (!mounted) return;
    setState(() {
      _nextRunAt = next;
      _cronError = error;
    });
  }

  void _applyQuickCron(String expr) {
    _cronCtrl.text = expr;
    _cronDebounce?.cancel();
    _recomputeCron();
    _scheduleSave();
  }

  String _formatDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  void _selectPreset(String id) {
    if (_presetId == id) return;
    setState(() => _presetId = id);
    _scheduleSave();
  }

  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    _scheduleSave();
  }

  String get _subtitle {
    final element = _scene?.elementById(widget.selection.elementId ?? '')?.name;
    final type = _scene?.typeById(_presetId)?.name;
    return '${element ?? '未选择元素'} · ${type ?? '未选择模板'}';
  }

  @override
  Widget build(BuildContext context) {
    return WorkspaceShell(
      title: 'Auto',
      subtitle: _subtitle,
      accent: _accent,
      symbol: SceneSymbolKind.auto,
      statusLabel: _enabled ? '已启用' : '未启用',
      leftPanel: _buildLeftPanel(),
      body: _buildBody(),
    );
  }

  // ---------------- 左侧：预设模板 + 运行记录 ----------------

  Widget _buildLeftPanel() {
    final p = ScenePalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < _kCompactWidth;
    final types = _scene?.types ?? const <SceneProjectType>[];
    return ListView(
      padding: const EdgeInsets.only(right: 2),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text(
                '预设模板',
                style: SceneTokens.sceneTitle(16, color: p.textPrimary),
              ),
              const Spacer(),
              Text(
                '${types.length} 个',
                style: SceneTokens.sceneCaption(11, color: p.textTertiary),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: p.glassDecoration(radius: SceneTokens.radiusSmall),
          child: Column(
            children: [
              for (var i = 0; i < types.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _PresetTile(
                  type: types[i],
                  selected: types[i].id == _presetId,
                  accent: _accent,
                  onTap: () => _selectPreset(types[i].id),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '运行记录',
            style: SceneTokens.sceneTitle(16, color: p.textPrimary),
          ),
        ),
        Container(
          // 运行记录高度受限（窄屏 160，桌面最多 260），条目超出时在内部滚动。
          constraints: BoxConstraints(maxHeight: narrow ? 160 : 260),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: p.glassDecoration(radius: SceneTokens.radiusSmall),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            itemCount: _records.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: p.divider),
            itemBuilder: (context, i) =>
                _RunRecordTile(record: _records[i], accent: _accent),
          ),
        ),
      ],
    );
  }

  // ---------------- 主区 ----------------

  Widget _buildBody() {
    final narrow = MediaQuery.sizeOf(context).width < _kCompactWidth;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWorkflow(narrow: narrow),
          const SizedBox(height: 16),
          _buildSchedule(),
          const SizedBox(height: 16),
          _buildEnable(),
        ],
      ),
    );
  }

  Widget _buildWorkflow({required bool narrow}) {
    final p = ScenePalette.of(context);
    final presetName = _scene?.typeById(_presetId)?.name ?? '空白工作流';
    final cards = <Widget>[
      _NodeCard(
        icon: Icons.bolt_rounded,
        title: '触发',
        subtitle: 'Cron 定时触发',
        accent: _accent,
      ),
      _NodeCard(
        icon: Icons.account_tree_outlined,
        title: '处理',
        subtitle: presetName,
        accent: _accent,
      ),
      _NodeCard(
        icon: Icons.send_rounded,
        title: '输出',
        subtitle: '邮件 · Webhook 通知',
        accent: _accent,
      ),
    ];
    return WorkspaceSection(
      title: '工作流 · 节点示意',
      accent: _accent,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Dify',
          style: SceneTokens.sceneCaption(
            10,
            color: _accentText(p, _accent),
            weight: FontWeight.w700,
          ),
        ),
      ),
      // 窄屏改为纵向排列：触发 ↓ 处理 ↓ 输出。
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cards[0],
                _VerticalNodeConnector(accent: _accent),
                cards[1],
                _VerticalNodeConnector(accent: _accent),
                cards[2],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: cards[0]),
                _NodeConnector(accent: _accent),
                Expanded(child: cards[1]),
                _NodeConnector(accent: _accent),
                Expanded(child: cards[2]),
              ],
            ),
    );
  }

  Widget _buildSchedule() {
    final p = ScenePalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < _kCompactWidth;
    return WorkspaceSection(
      title: '调度 · Cron 表达式',
      accent: _accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 窄屏：输入框与快捷频率纵向排列，快捷行可横向滚动。
          Container(
            decoration: BoxDecoration(
              color: p.inputFill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _cronError != null
                    ? _dangerColor(p).withValues(alpha: 0.55)
                    : p.glassBorder,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _cronCtrl,
              onChanged: _onCronChanged,
              cursorColor: _accent,
              style: SceneTokens.sceneBody(14, color: p.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                hintText: '0 9 * * *',
                hintStyle: SceneTokens.sceneBody(13, color: p.textTertiary),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  '快捷：',
                  style: SceneTokens.sceneCaption(11, color: p.textTertiary),
                ),
                _QuickCronButton(
                  label: '每小时',
                  accent: _accent,
                  minHeight: narrow ? 44 : 32,
                  onTap: () => _applyQuickCron('0 * * * *'),
                ),
                const SizedBox(width: 8),
                _QuickCronButton(
                  label: '每天 9 点',
                  accent: _accent,
                  minHeight: narrow ? 44 : 32,
                  onTap: () => _applyQuickCron('0 9 * * *'),
                ),
                const SizedBox(width: 8),
                _QuickCronButton(
                  label: '每周一',
                  accent: _accent,
                  minHeight: narrow ? 44 : 32,
                  onTap: () => _applyQuickCron('0 9 * * 1'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_cronError != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: _dangerColor(p),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _cronError!,
                    style: SceneTokens.sceneBody(11.5, color: _dangerColor(p)),
                  ),
                ),
              ],
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _accent.withValues(alpha: 0.28)),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 15, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _nextRunAt == null
                          ? '尚未计算出下次运行时间'
                          : '下次运行：${_formatDateTime(_nextRunAt!)}',
                      style: SceneTokens.sceneBody(12.5, color: p.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '格式：分 时 日 月 周，支持 * / 数字 / a-b / 步进 */n / 逗号列表。',
            style: SceneTokens.sceneCaption(10.5, color: p.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildEnable() {
    final p = ScenePalette.of(context);
    return WorkspaceSection(
      title: '任务状态',
      accent: _accent,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _enabled ? '已启用' : '未启用',
                  style: SceneTokens.sceneBody(
                    14,
                    color: p.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '概念版仅记录状态，不会真正调度。',
                  style: SceneTokens.sceneCaption(11, color: p.textTertiary),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 1.15,
            child: Switch(
              value: _enabled,
              onChanged: _setEnabled,
              activeThumbColor: _accent,
              activeTrackColor: _accent.withValues(alpha: 0.35),
              inactiveThumbColor: p.textTertiary,
              inactiveTrackColor: p.inputFill,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 左侧列表项 ----------------

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.type,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final SceneProjectType type;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: accent.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: SceneTokens.durationFast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.14) : p.glassFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      type.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SceneTokens.sceneBody(
                        12.5,
                        color: selected ? p.textPrimary : p.textSecondary,
                        weight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_rounded, size: 14, color: accent),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                type.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: SceneTokens.sceneCaption(10.5, color: p.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunRecord {
  _RunRecord({required this.time, required this.ok, required this.duration});

  final DateTime time;
  final bool ok;
  final String duration;
}

class _RunRecordTile extends StatelessWidget {
  const _RunRecordTile({required this.record, required this.accent});

  final _RunRecord record;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    String two(int v) => v.toString().padLeft(2, '0');
    final time =
        '${two(record.time.month)}-${two(record.time.day)} '
        '${two(record.time.hour)}:${two(record.time.minute)}';
    final color = record.ok ? _successColor(p) : _dangerColor(p);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              time,
              style: SceneTokens.sceneCaption(11, color: p.textSecondary),
            ),
          ),
          Text(
            record.ok ? '成功' : '失败',
            style: SceneTokens.sceneCaption(
              10.5,
              color: color,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            record.duration,
            style: SceneTokens.sceneCaption(10.5, color: p.textTertiary),
          ),
        ],
      ),
    );
  }
}

// ---------------- 主区小部件 ----------------

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.glassFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: SceneTokens.sceneBody(
              13,
              color: p.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SceneTokens.sceneCaption(10.5, color: p.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _NodeConnector extends StatelessWidget {
  const _NodeConnector({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1.2, color: accent.withValues(alpha: 0.3)),
          ),
          Icon(
            Icons.arrow_forward_ios_rounded,
            size: 9,
            color: accent.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

/// 窄屏下的纵向连线：触发 ↓ 处理 ↓ 输出。
class _VerticalNodeConnector extends StatelessWidget {
  const _VerticalNodeConnector({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: Column(
        children: [
          Expanded(
            child: Container(width: 1.2, color: accent.withValues(alpha: 0.3)),
          ),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: accent.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

class _QuickCronButton extends StatelessWidget {
  const _QuickCronButton({
    required this.label,
    required this.accent,
    required this.onTap,
    this.minHeight = 32,
  });

  final String label;
  final Color accent;
  final VoidCallback onTap;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final p = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: accent.withValues(alpha: 0.08),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: p.inputFill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.glassBorder),
          ),
          child: Text(
            label,
            style: SceneTokens.sceneBody(
              11,
              color: p.textSecondary,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Cron 解析 ----------------

class _CronSpec {
  _CronSpec({
    required this.minutes,
    required this.hours,
    required this.days,
    required this.months,
    required this.weekdays,
  });

  final List<int> minutes; // 升序
  final List<int> hours; // 升序
  final Set<int> days;
  final Set<int> months;
  final Set<int> weekdays; // 0-6，0 表示周日
}

/// 解析 5 段 Cron：分 时 日 月 周。
///
/// 概念版按字段交集判断（日与周同时限定时不采用标准 Cron 的「或」语义）。
_CronSpec? _parseCron(String expr) {
  final parts = expr.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return null;

  final minutes = _parseField(parts[0], 0, 59);
  final hours = _parseField(parts[1], 0, 23);
  final days = _parseField(parts[2], 1, 31);
  final months = _parseField(parts[3], 1, 12);
  final weekdaysRaw = _parseField(parts[4], 0, 7);
  if (minutes == null ||
      hours == null ||
      days == null ||
      months == null ||
      weekdaysRaw == null) {
    return null;
  }

  return _CronSpec(
    minutes: minutes.toList()..sort(),
    hours: hours.toList()..sort(),
    days: days,
    months: months,
    weekdays: weekdaysRaw.map((v) => v == 7 ? 0 : v).toSet(),
  );
}

/// 解析单个字段，支持 `*`、数字、`a-b`、`*/n`、逗号列表。
Set<int>? _parseField(String field, int min, int max) {
  final result = <int>{};
  for (final raw in field.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) return null;

    if (part == '*') {
      for (var v = min; v <= max; v++) {
        result.add(v);
      }
      continue;
    }

    if (part.contains('/')) {
      final segments = part.split('/');
      if (segments.length != 2) return null;
      // 概念版仅支持 `*/n` 步进写法
      if (segments[0] != '*') return null;
      final step = int.tryParse(segments[1]);
      if (step == null || step <= 0) return null;
      for (var v = min; v <= max; v += step) {
        result.add(v);
      }
      continue;
    }

    if (part.contains('-')) {
      final segments = part.split('-');
      if (segments.length != 2) return null;
      final start = int.tryParse(segments[0]);
      final end = int.tryParse(segments[1]);
      if (start == null ||
          end == null ||
          start < min ||
          end > max ||
          start > end) {
        return null;
      }
      for (var v = start; v <= end; v++) {
        result.add(v);
      }
      continue;
    }

    final value = int.tryParse(part);
    if (value == null || value < min || value > max) return null;
    result.add(value);
  }
  if (result.isEmpty) return null;
  return result;
}

/// 计算 [from] 之后的下一次运行时间，最多向后搜索 90 天。
DateTime? _nextRun(String expr, DateTime from) {
  final spec = _parseCron(expr);
  if (spec == null) return null;

  final startDay = DateTime(from.year, from.month, from.day);
  final limit = from.add(const Duration(days: 90));

  for (var offset = 0; offset <= 90; offset++) {
    final day = DateTime(startDay.year, startDay.month, startDay.day + offset);
    if (!spec.months.contains(day.month)) continue;
    if (!spec.days.contains(day.day)) continue;
    if (!spec.weekdays.contains(day.weekday % 7)) continue;

    for (final hour in spec.hours) {
      for (final minute in spec.minutes) {
        final candidate = DateTime(day.year, day.month, day.day, hour, minute);
        if (candidate.isAfter(from) && !candidate.isAfter(limit)) {
          return candidate;
        }
      }
    }
  }
  return null;
}
