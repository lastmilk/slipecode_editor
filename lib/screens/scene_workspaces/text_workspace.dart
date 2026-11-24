import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/scene.dart';
import '../../services/scene_registry.dart';
import '../../services/scene_session_service.dart';
import '../../services/text_engine/text_engine.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import 'workspace_shell.dart';

/// 移动端「仅预览」断点：小于该宽度时隐藏所有文档编辑控件。
const double _kMobilePreviewBreakpoint = 700;

/// Text 工作台（概念版 · 预览编辑）。
///
/// 覆盖 Word / PPT / Excel / PDF 四类产物，编辑内容仅保存在本地草稿；
/// 「使用 OnlyOffice 打开」走 [TextEngineRegistry]，未配置时只给出接入说明，
/// 不发起任何网络请求。
class TextWorkspace extends StatefulWidget {
  const TextWorkspace({super.key, required this.selection, this.draft});

  final SceneSelection selection;
  final SceneDraft? draft;

  @override
  State<TextWorkspace> createState() => _TextWorkspaceState();
}

/// 幻灯片数据：标题与正文各用一个控制器。
class _SlideData {
  _SlideData({String title = '', String body = ''})
      : titleCtrl = TextEditingController(text: title),
        bodyCtrl = TextEditingController(text: body);

  final TextEditingController titleCtrl;
  final TextEditingController bodyCtrl;
}

const String _defaultWordText = '''清晨的光从百叶窗的缝隙里落下来，在书桌上铺开一条细长的金线。

这是《长夜将明》的第一章。林深把最后一页稿纸压进信封，抬头看了一眼墙上的挂钟——七点四十分，距离交稿还有二十分钟。

他忽然意识到，真正难写的从来不是故事本身，而是那些没有被说出口的部分。''';

const List<List<String>> _defaultSlideSeed = [
  ['场景化工作流', '用自然语言描述意图，AI 负责还原成可运行的产物。'],
  ['三分钟完成原型', '从场景大厅到工作台，选择、生成、预览一气呵成。'],
  ['下一步计划', '接入真实视频渲染与 OnlyOffice 编辑内核。'],
];

class _TextWorkspaceState extends State<TextWorkspace> {
  SceneDefinition? _scene;
  TextDocumentType _docType = TextDocumentType.word;

  final TextEditingController _wordCtrl =
      TextEditingController(text: _defaultWordText);
  final List<_SlideData> _slides = [];
  final List<List<String>> _grid = [];
  final Map<String, TextEditingController> _cellCtrls = {};
  int _activeSlide = 0;

  SceneDraft? _draft;
  Timer? _saveTimer;

  Color get _accent => _scene?.accent ?? const Color(0xFFFB923C);

  @override
  void initState() {
    super.initState();
    _scene = SceneRegistry.byId(widget.selection.sceneId);
    _docType = _typeFromElement(widget.selection.elementId);
    _restore();
    _draft = widget.draft;
    if (_draft == null) {
      unawaited(_saveNow());
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_saveNow());
    _wordCtrl.dispose();
    for (final slide in _slides) {
      slide.titleCtrl.dispose();
      slide.bodyCtrl.dispose();
    }
    for (final ctrl in _cellCtrls.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  TextDocumentType _typeFromElement(String? elementId) => switch (elementId) {
        'ppt' => TextDocumentType.ppt,
        'excel' => TextDocumentType.excel,
        'pdf' => TextDocumentType.pdf,
        _ => TextDocumentType.word,
      };

  // ---------------- 草稿 ----------------

  void _restore() {
    final payload = widget.draft?.payload;
    if (payload == null) {
      _initDefaults();
      return;
    }

    final rawType = payload['docType'];
    if (rawType is String) {
      for (final type in TextDocumentType.values) {
        if (type.name == rawType) {
          _docType = type;
          break;
        }
      }
    }

    final wordText = payload['wordText'];
    if (wordText is String && wordText.isNotEmpty) {
      _wordCtrl.text = wordText;
    }

    final rawSlides = payload['slides'];
    if (rawSlides is List && rawSlides.isNotEmpty) {
      _slides.clear();
      for (final raw in rawSlides) {
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        _slides.add(
          _SlideData(
            title: map['title'] as String? ?? '',
            body: map['body'] as String? ?? '',
          ),
        );
      }
    }

    final rawGrid = payload['grid'];
    if (rawGrid is List && rawGrid.isNotEmpty) {
      final rows = <List<String>>[];
      for (final rawRow in rawGrid) {
        if (rawRow is! List) continue;
        rows.add(rawRow.map((cell) => '$cell').toList());
      }
      if (rows.isNotEmpty) {
        final maxCols = rows.fold<int>(0, (m, row) => row.length > m ? row.length : m);
        _grid
          ..clear()
          ..addAll(
            rows.map(
              (row) => [
                ...row,
                for (var i = row.length; i < maxCols; i++) '',
              ],
            ),
          );
      }
    }

    final active = payload['activeSlide'];
    if (active is int && active >= 0 && active < _slides.length) {
      _activeSlide = active;
    }

    // 兜底：草稿可能在异常情况下缺失关键数据
    _initDefaults();
  }

  void _initDefaults() {
    if (_slides.isEmpty) {
      for (final item in _defaultSlideSeed) {
        _slides.add(_SlideData(title: item[0], body: item[1]));
      }
    }
    if (_grid.isEmpty) {
      _grid.addAll(_defaultGrid());
    }
  }

  List<List<String>> _defaultGrid() {
    final rows = <List<String>>[
      ['月份', '收入', '成本', '利润', '增长率', '备注'],
    ];
    for (var i = 1; i <= 9; i++) {
      final revenue = 12000 + i * 860;
      final cost = 8000 + i * 420;
      rows.add([
        '$i 月',
        '$revenue',
        '$cost',
        '${revenue - cost}',
        '${8 + i}%',
        i == 9 ? '待复核' : '',
      ]);
    }
    return rows;
  }

  Map<String, dynamic> _payload() => {
        'docType': _docType.name,
        'wordText': _wordCtrl.text,
        'slides': _slides
            .map(
              (slide) => {
                'title': slide.titleCtrl.text,
                'body': slide.bodyCtrl.text,
              },
            )
            .toList(),
        'grid': _grid,
        'activeSlide': _activeSlide,
      };

  Future<void> _saveNow() async {
    final payload = _payload();
    final current = _draft;
    if (current == null) {
      _draft = await SceneSessionService.instance
          .createDraft(widget.selection, payload: payload);
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

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final palette = ScenePalette.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: SceneTokens.sceneBody(
              13,
              color: palette.isDark ? palette.textPrimary : Colors.white,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: error
              ? (palette.isDark
                    ? const Color(0xFF3A1518)
                    : const Color(0xFF8C2F35))
              : (palette.isDark
                    ? const Color(0xFF1B1B21)
                    : const Color(0xFF2B2C33)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _selectDocType(TextDocumentType type) {
    if (_docType == type) return;
    setState(() => _docType = type);
    _scheduleSave();
  }

  void _addSlide() {
    setState(() {
      _slides.add(
        _SlideData(title: '新页面 ${_slides.length + 1}', body: '在这里补充要点。'),
      );
      _activeSlide = _slides.length - 1;
    });
    _scheduleSave();
  }

  void _selectSlide(int index) {
    if (_activeSlide == index) return;
    setState(() => _activeSlide = index);
    _scheduleSave();
  }

  TextEditingController _cellCtrl(int row, int col) {
    final key = '${row}_$col';
    return _cellCtrls.putIfAbsent(
      key,
      () => TextEditingController(text: _grid[row][col]),
    );
  }

  void _setCell(int row, int col, String value) {
    if (row < 0 || row >= _grid.length) return;
    if (col < 0 || col >= _grid[row].length) return;
    _grid[row][col] = value;
    final ctrl = _cellCtrls['${row}_$col'];
    if (ctrl != null && ctrl.text != value) {
      ctrl.text = value;
    }
  }

  void _addRow() {
    if (_grid.isEmpty) return;
    setState(() {
      _grid.add(List<String>.filled(_grid.first.length, ''));
    });
    _scheduleSave();
  }

  void _addColumn() {
    if (_grid.isEmpty) return;
    setState(() {
      for (final row in _grid) {
        row.add('');
      }
    });
    _scheduleSave();
  }

  void _removeRow() {
    if (_grid.length <= 1) {
      _toast('至少保留一行', error: true);
      return;
    }
    setState(() {
      final removed = _grid.removeLast();
      final rowIndex = _grid.length;
      for (var col = 0; col < removed.length; col++) {
        _cellCtrls.remove('${rowIndex}_$col')?.dispose();
      }
    });
    _scheduleSave();
  }

  void _removeColumn() {
    if (_grid.isEmpty || _grid.first.length <= 1) {
      _toast('至少保留一列', error: true);
      return;
    }
    setState(() {
      final colIndex = _grid.first.length - 1;
      for (var row = 0; row < _grid.length; row++) {
        if (_grid[row].isEmpty) continue;
        _grid[row].removeLast();
        _cellCtrls.remove('${row}_$colIndex')?.dispose();
      }
    });
    _scheduleSave();
  }

  void _insertAiText(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    setState(() {
      switch (_docType) {
        case TextDocumentType.word:
        case TextDocumentType.pdf:
          final current = _wordCtrl.text.trimRight();
          _wordCtrl.text = current.isEmpty ? clean : '$current\n\n$clean';
          _wordCtrl.selection =
              TextSelection.collapsed(offset: _wordCtrl.text.length);
        case TextDocumentType.ppt:
          if (_slides.isNotEmpty && _activeSlide < _slides.length) {
            _slides[_activeSlide].bodyCtrl.text = clean;
          }
        case TextDocumentType.excel:
          if (_grid.isNotEmpty) {
            var targetRow = -1;
            for (var row = 1; row < _grid.length; row++) {
              if (_grid[row].isNotEmpty && _grid[row][0].trim().isEmpty) {
                targetRow = row;
                break;
              }
            }
            if (targetRow == -1) {
              _grid.add(List<String>.filled(_grid.first.length, ''));
              targetRow = _grid.length - 1;
            }
            _setCell(targetRow, 0, clean);
          }
      }
    });
    _scheduleSave();
    _toast('已插入到当前文档');
  }

  Future<void> _exportPdf() async {
    final engine = await TextEngineRegistry.instance.resolveActive();
    final result =
        await engine.exportPdf('concept_${_docType.name}.pdf');
    if (!mounted) return;
    _toast(result.message, error: !result.ok);
  }

  // ---------------- OnlyOffice 配置引导 ----------------

  Future<void> _openOnlyOffice() async {
    final isMobile =
        MediaQuery.sizeOf(context).width < _kMobilePreviewBreakpoint;
    final registry = TextEngineRegistry.instance;
    final resolved = await registry.resolveSelection();
    if (!mounted) return;

    final onlyOffice = registry.onlyOffice;
    final initialUrl = await onlyOffice.serverUrl();
    final configured = await onlyOffice.isConfigured();
    if (!mounted) return;

    final serverCtrl = TextEditingController(text: initialUrl);
    final jwtCtrl = TextEditingController();
    var savedConfigured = configured;
    var statusText = '';
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> saveConfig() async {
              setDialogState(() => saving = true);
              await onlyOffice.saveConfig(
                serverUrl: serverCtrl.text,
                jwtSecret: jwtCtrl.text,
              );
              final ok = await onlyOffice.isConfigured();
              if (!dialogContext.mounted) return;
              jwtCtrl.clear();
              setDialogState(() {
                saving = false;
                savedConfigured = ok;
                statusText = ok
                    ? '配置已保存：服务地址写入本地配置，JWT 密钥仅存入安全存储。'
                    : '尚未完整配置：服务地址与 JWT 密钥都填写后才能启用 OnlyOffice。';
              });
            }

            Future<void> openLocalPreview() async {
              final result = await TextEngineRegistry.instance.mock.openDocument(
                'concept_${_docType.name}.${_docType.extension}',
              );
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (!mounted) return;
              _toast(result.message, error: !result.ok);
            }

            final palette = ScenePalette.of(dialogContext);
            return Dialog(
              backgroundColor: palette.glassFillStrong,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: _accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '使用 OnlyOffice 打开',
                              style: SceneTokens.sceneTitle(
                                17,
                                color: palette.textPrimary,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => Navigator.of(dialogContext).pop(),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: palette.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (isMobile) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: palette.glassFill,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: palette.divider),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.visibility_outlined,
                                size: 14,
                                color: palette.textSecondary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '移动端仅支持配置 OnlyOffice，打开文档请在桌面端使用。',
                                  style: SceneTokens.sceneBody(
                                    11.5,
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.glassFill,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: palette.glassBorder),
                        ),
                        child: Column(
                          children: [
                            _DialogInfoRow(
                              label: '当前引擎',
                              value: resolved.engine.displayName,
                            ),
                            const SizedBox(height: 6),
                            _DialogInfoRow(
                              label: '是否降级',
                              value: resolved.isFallback ? '是' : '否',
                            ),
                            const SizedBox(height: 6),
                            _DialogInfoRow(
                              label: 'OnlyOffice 状态',
                              value: savedConfigured ? '已配置' : '未配置',
                            ),
                            if (resolved.fallbackMessage != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                resolved.fallbackMessage!,
                                style: SceneTokens.sceneBody(
                                  11.5,
                                  color: palette.isDark
                                      ? const Color(0xFFFBBF24)
                                      : const Color(0xFFB45309),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '服务地址（DocumentServer）',
                        style: SceneTokens.sceneCaption(
                          11.5,
                          color: palette.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: serverCtrl,
                        cursorColor: _accent,
                        style: SceneTokens.sceneBody(
                          13,
                          color: palette.textPrimary,
                        ),
                        decoration: _dialogInput(
                          'https://docs.example.com',
                          palette,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'JWT 密钥（仅存安全存储，界面掩码显示）',
                        style: SceneTokens.sceneCaption(
                          11.5,
                          color: palette.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: jwtCtrl,
                        obscureText: true,
                        cursorColor: _accent,
                        style: SceneTokens.sceneBody(
                          13,
                          color: palette.textPrimary,
                        ),
                        decoration: _dialogInput(
                          '留空表示不修改现有密钥',
                          palette,
                        ),
                      ),
                      if (statusText.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          statusText,
                          style: SceneTokens.sceneBody(
                            11.5,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 40,
                              child: FilledButton(
                                onPressed: saving ? null : saveConfig,
                                style: FilledButton.styleFrom(
                                  backgroundColor: _accent,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: Text(
                                  saving ? '保存中…' : '保存配置',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SizedBox(
                              height: 40,
                              child: OutlinedButton(
                                onPressed: openLocalPreview,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: palette.textPrimary,
                                  side: BorderSide(color: palette.glassBorder),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  '用本地预览打开',
                                  style: TextStyle(fontSize: 12.5),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.codeBackground,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: palette.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '部署说明（正式接入）',
                              style: SceneTokens.sceneCaption(
                                11.5,
                                color: palette.textSecondary,
                                weight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '1. Docker 部署 DocumentServer，开启 JWT：\n'
                              '   docker run -i -t -d -p 8080:80 --name onlyoffice \\\n'
                              '     -e JWT_ENABLED=true -e JWT_SECRET=*** \\\n'
                              '     onlyoffice/documentserver\n'
                              '2. Windows / macOS / Linux 三端统一使用 webview_cef 承载编辑器；\n'
                              '3. 本地文档需通过「本机临时静态服务 + 一次性 token」或后端中转暴露为 HTTP 地址。',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                height: 1.55,
                                color: palette.codeForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '概念版不会发起网络请求，也不会把 JWT 明文写入日志或草稿。',
                        style: SceneTokens.sceneCaption(
                          10.5,
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
      },
    );

    // 对话框退场动画期间 TextField 仍引用控制器，延后释放避免释放后访问
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        serverCtrl.dispose();
        jwtCtrl.dispose();
      }),
    );
  }

  InputDecoration _dialogInput(String hint, ScenePalette palette) {
    return InputDecoration(
      hintText: hint,
      hintStyle: SceneTokens.sceneBody(12, color: palette.textTertiary),
      isDense: true,
      filled: true,
      fillColor: palette.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: palette.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: _accent.withValues(alpha: 0.6)),
      ),
    );
  }

  String get _subtitle {
    final element = _scene?.elementById(widget.selection.elementId ?? '')?.name;
    final type = _scene?.typeById(widget.selection.typeId ?? '')?.name;
    return '${element ?? '未选择元素'} · ${type ?? '未选择模板'} · 概念版 · 预览编辑';
  }

  @override
  Widget build(BuildContext context) {
    // 移动端（< 700）：全部文档进入只读预览，不允许通过插入/编辑修改内容。
    final isMobile =
        MediaQuery.sizeOf(context).width < _kMobilePreviewBreakpoint;
    return WorkspaceShell(
      title: 'Text',
      subtitle: _subtitle,
      accent: _accent,
      symbol: SceneSymbolKind.text,
      statusLabel: '概念版 · 预览编辑',
      actions: [
        _TopBarButton(
          label: '使用 OnlyOffice 打开',
          icon: Icons.open_in_new_rounded,
          accent: _accent,
          onTap: _openOnlyOffice,
        ),
        // 移动端仅预览，不提供导出入口。
        if (!isMobile && _docType == TextDocumentType.pdf)
          _TopBarButton(
            label: '导出 PDF',
            icon: Icons.picture_as_pdf_outlined,
            accent: _accent,
            onTap: _exportPdf,
          ),
      ],
      rightPanel: WorkspaceAiPanel(
        accentLabel: 'Text',
        accent: _accent,
        cannedResponses: const [
          '建议先给结论，再按「背景 → 证据 → 结论」三段组织，我已据此改写当前段落。',
          '我把标题改为「场景化工作流的三个支点」，并在开头补了一句钩子。',
          '已把这段压缩到 180 字，保留数据与结论，删掉重复的修饰。',
          '表格中的「增长率」可由利润与成本推导，建议改为公式列并补充口径说明。',
        ],
        onSend: (text) async {
          // 概念版：仅由面板模拟回复，真实模型接入位置在此处
        },
        // 移动端禁用插入，点击时仅提示「移动端仅支持预览」。
        onInsert: isMobile ? (_) => _toast('移动端仅支持预览') : _insertAiText,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isMobile) ...[
            const _MobilePreviewBanner(),
            const SizedBox(height: 12),
          ],
          _buildDocTabs(isMobile: isMobile),
          const SizedBox(height: 14),
          Expanded(child: _buildEditor(isMobile: isMobile)),
        ],
      ),
    );
  }

  Widget _buildDocTabs({required bool isMobile}) {
    final tabs = [
      for (var i = 0; i < TextDocumentType.values.length; i++)
        _DocTab(
          type: TextDocumentType.values[i],
          selected: TextDocumentType.values[i] == _docType,
          accent: _accent,
          onTap: () => _selectDocType(TextDocumentType.values[i]),
        ),
    ];
    // 移动端四态按钮横向滚动，避免挤压与溢出。
    if (isMobile) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              SizedBox(width: 128, child: tabs[i]),
            ],
          ],
        ),
      );
    }
    return Row(
      children: [
        for (var i = 0; i < tabs.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: tabs[i]),
        ],
      ],
    );
  }

  Widget _buildEditor({required bool isMobile}) {
    return switch (_docType) {
      TextDocumentType.word =>
        _buildPaperEditor(pdf: false, isMobile: isMobile),
      TextDocumentType.pdf => _buildPaperEditor(pdf: true, isMobile: isMobile),
      TextDocumentType.ppt => _buildPptEditor(isMobile: isMobile),
      TextDocumentType.excel => _buildExcelEditor(isMobile: isMobile),
    };
  }

  // ---------------- Word / PDF：A4 纸张 ----------------

  Widget _buildPaperEditor({required bool pdf, required bool isMobile}) {
    final palette = ScenePalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  // 纸张本身始终保持白纸黑字，外层描边与阴影跟随主题。
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: palette.divider),
                  boxShadow: [
                    BoxShadow(
                      color: palette.shadow,
                      blurRadius: 30,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(36, 40, 36, 40),
                child: AspectRatio(
                  aspectRatio: 1 / 1.414,
                  child: TextField(
                    controller: _wordCtrl,
                    expands: true,
                    maxLines: null,
                    readOnly: isMobile,
                    enableInteractiveSelection: true,
                    showCursor: !isMobile,
                    textAlignVertical: TextAlignVertical.top,
                    cursorColor: const Color(0xFF3B3F4A),
                    onChanged: (_) => _scheduleSave(),
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.9,
                      color: Color(0xFF2A2E37),
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                      hintText: '开始写作…',
                      hintStyle: TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF9AA0AA),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    pdf ? '第 1 / 1 页' : '共 1 页',
                    style: SceneTokens.sceneCaption(
                      11,
                      color: palette.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  if (pdf && !isMobile)
                    SizedBox(
                      height: 34,
                      child: FilledButton.icon(
                        onPressed: _exportPdf,
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(
                          Icons.picture_as_pdf_outlined,
                          size: 14,
                        ),
                        label: const Text(
                          '导出 PDF',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- PPT：缩略图 + 当前页 ----------------

  Widget _buildPptEditor({required bool isMobile}) {
    // 窄屏单列：顶部横向缩略图条 + 下方当前页。
    if (isMobile) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _slides.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) => SizedBox(
                  width: 150,
                  child: Center(
                    child: _SlideThumb(
                      index: index,
                      title: _slides[index].titleCtrl.text,
                      selected: index == _activeSlide,
                      accent: _accent,
                      onTap: () => _selectSlide(index),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _buildSlideCanvas(isMobile: true),
          ],
        ),
      );
    }

    final palette = ScenePalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Column(
              children: [
                for (var i = 0; i < _slides.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _SlideThumb(
                    index: i,
                    title: _slides[i].titleCtrl.text,
                    selected: i == _activeSlide,
                    accent: _accent,
                    onTap: () => _selectSlide(i),
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: _addSlide,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.textSecondary,
                      side: BorderSide(color: palette.glassBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 14),
                    label: const Text(
                      '新增页',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: _buildSlideCanvas(isMobile: false)),
        ],
      ),
    );
  }

  Widget _buildSlideCanvas({required bool isMobile}) {
    if (_slides.isEmpty) return const SizedBox.shrink();
    final slide = _slides[_activeSlide];
    final palette = ScenePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        // 幻灯片纸面固定白底，内部文字保持深色，避免深色主题下不可见。
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.divider),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.all(28),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: slide.titleCtrl,
              readOnly: isMobile,
              enableInteractiveSelection: true,
              showCursor: !isMobile,
              cursorColor: const Color(0xFF3B3F4A),
              onChanged: (_) {
                setState(() {});
                _scheduleSave();
              },
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1D2330),
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                hintText: '页面标题',
                hintStyle: TextStyle(
                  fontSize: 19,
                  color: Color(0xFF9AA0AA),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(height: 1, color: const Color(0xFFE2E0D8)),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: slide.bodyCtrl,
                maxLines: null,
                expands: true,
                readOnly: isMobile,
                enableInteractiveSelection: true,
                showCursor: !isMobile,
                textAlignVertical: TextAlignVertical.top,
                cursorColor: const Color(0xFF3B3F4A),
                onChanged: (_) => _scheduleSave(),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: Color(0xFF3A3F4A),
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: '在这里输入正文…',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9AA0AA),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                '${_activeSlide + 1} / ${_slides.length}',
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF9AA0AA),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Excel：轻量表格网格 ----------------

  Widget _buildExcelEditor({required bool isMobile}) {
    if (_grid.isEmpty) return const SizedBox.shrink();
    final palette = ScenePalette.of(context);
    final columns = _grid.first.length;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 移动端隐藏所有行列编辑按钮，仅保留只读网格。
          if (isMobile)
            Text(
              '${_grid.length} 行 × $columns 列 · 移动端仅支持预览',
              style: SceneTokens.sceneCaption(11, color: palette.textTertiary),
            )
          else
            Row(
              children: [
                _SmallActionButton(
                  label: '加一行',
                  icon: Icons.add_rounded,
                  accent: _accent,
                  onTap: _addRow,
                ),
                const SizedBox(width: 8),
                _SmallActionButton(
                  label: '加一列',
                  icon: Icons.add_rounded,
                  accent: _accent,
                  onTap: _addColumn,
                ),
                const SizedBox(width: 8),
                _SmallActionButton(
                  label: '删一行',
                  icon: Icons.remove_rounded,
                  accent: _accent,
                  danger: true,
                  onTap: _grid.length > 1 ? _removeRow : null,
                ),
                const SizedBox(width: 8),
                _SmallActionButton(
                  label: '删一列',
                  icon: Icons.remove_rounded,
                  accent: _accent,
                  danger: true,
                  onTap: columns > 1 ? _removeColumn : null,
                ),
                const SizedBox(width: 12),
                Text(
                  '${_grid.length} 行 × $columns 列',
                  style: SceneTokens.sceneCaption(
                    11,
                    color: palette.textTertiary,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: palette.glassDecoration(
              radius: SceneTokens.radiusSmall,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _GridCorner(),
                      for (var col = 0; col < columns; col++)
                        _GridHeaderCell(
                          label: _columnLabel(col),
                          accent: _accent,
                        ),
                    ],
                  ),
                  for (var row = 0; row < _grid.length; row++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _GridRowNumber(index: row + 1),
                        for (var col = 0; col < _grid[row].length; col++)
                          _GridCell(
                            controller: _cellCtrl(row, col),
                            accent: _accent,
                            readOnly: isMobile,
                            onChanged: (value) {
                              _grid[row][col] = value;
                              _scheduleSave();
                            },
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _columnLabel(int index) {
    if (index < 26) return String.fromCharCode(65 + index);
    return 'A${index - 25}';
  }
}

// ---------------- 顶部按钮与标签 ----------------

class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        hoverColor: accent.withValues(alpha: 0.08),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: palette.glassFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: SceneTokens.sceneBody(
                  11.5,
                  color: palette.textSecondary,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocTab extends StatelessWidget {
  const _DocTab({
    required this.type,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final TextDocumentType type;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  IconData get _icon => switch (type) {
        TextDocumentType.word => Icons.description_outlined,
        TextDocumentType.ppt => Icons.slideshow_outlined,
        TextDocumentType.excel => Icons.table_chart_outlined,
        TextDocumentType.pdf => Icons.picture_as_pdf_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        hoverColor: accent.withValues(alpha: 0.08),
        child: AnimatedContainer(
          duration: SceneTokens.durationFast,
          height: 54,
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.16)
                : palette.glassFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.6)
                  : palette.glassBorder,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _icon,
                size: 16,
                color: selected ? accent : palette.textTertiary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  type.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    13,
                    color: selected
                        ? palette.textPrimary
                        : palette.textSecondary,
                    weight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogInfoRow extends StatelessWidget {
  const _DialogInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: SceneTokens.sceneCaption(11.5, color: palette.textTertiary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: SceneTokens.sceneBody(11.5, color: palette.textPrimary),
          ),
        ),
      ],
    );
  }
}

// ---------------- PPT 缩略图 ----------------

class _SlideThumb extends StatelessWidget {
  const _SlideThumb({
    required this.index,
    required this.title,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final int index;
  final String title;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? accent : palette.glassBorder,
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              // 缩略图纸面固定白底，标题文字保持深色。
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: selected ? accent : const Color(0xFF9AA0AA),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2A2E37),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Excel 网格单元 ----------------

class _SmallActionButton extends StatelessWidget {
  const _SmallActionButton({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    const dangerColor = Color(0xFFE08A8A);
    final foreground = danger ? dangerColor : palette.textSecondary;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: accent.withValues(alpha: 0.08),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: palette.glassFill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: danger
                    ? dangerColor.withValues(alpha: 0.38)
                    : palette.glassBorder,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: danger ? dangerColor : accent),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: SceneTokens.sceneBody(11, color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GridCorner extends StatelessWidget {
  const _GridCorner();

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      width: 38,
      height: 32,
      decoration: BoxDecoration(
        color: palette.glassFillStrong,
        border: Border(
          right: BorderSide(color: palette.divider),
          bottom: BorderSide(color: palette.divider),
        ),
      ),
    );
  }
}

class _GridHeaderCell extends StatelessWidget {
  const _GridHeaderCell({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      width: 120,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        border: Border(
          right: BorderSide(color: palette.divider),
          bottom: BorderSide(color: palette.divider),
        ),
      ),
      child: Text(
        label,
        style: SceneTokens.sceneCaption(
          11,
          color: accent,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GridRowNumber extends StatelessWidget {
  const _GridRowNumber({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      width: 38,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.glassFill,
        border: Border(
          right: BorderSide(color: palette.divider),
          bottom: BorderSide(color: palette.divider),
        ),
      ),
      child: Text(
        '$index',
        style: SceneTokens.sceneCaption(10, color: palette.textTertiary),
      ),
    );
  }
}

class _GridCell extends StatelessWidget {
  const _GridCell({
    required this.controller,
    required this.accent,
    required this.onChanged,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final Color accent;
  final ValueChanged<String> onChanged;

  /// 移动端只读：点击仅显示内容，不进入编辑。
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      width: 120,
      height: 40,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: palette.divider),
          bottom: BorderSide(color: palette.divider),
        ),
      ),
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        enableInteractiveSelection: true,
        showCursor: !readOnly,
        onChanged: onChanged,
        cursorColor: accent,
        style: TextStyle(fontSize: 12, color: palette.textPrimary),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        ),
      ),
    );
  }
}

/// 移动端顶部提示条：本工作台仅提供预览。
class _MobilePreviewBanner extends StatelessWidget {
  const _MobilePreviewBanner();

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: palette.glassDecoration(radius: 14),
      child: Row(
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 16,
            color: palette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '移动端仅支持预览，编辑与导出请在桌面端进行。',
              style: SceneTokens.sceneBody(12, color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
