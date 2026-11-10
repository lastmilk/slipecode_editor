import 'package:flutter/material.dart';

import '../payloads/loader/loader_payload.dart';
import '../services/custom_payload_service.dart';
import '../services/github_actions_templates.dart';

/// 自定义 Payload 编辑器
///
/// 支持 Root / System / Block 三类：
/// - Root：环境变量组 + GitHub Actions workflow
/// - System：一个「端」的模板化目录结构
/// - Block：细分功能模块（Markdown）
class CustomPayloadEditorScreen extends StatefulWidget {
  /// 'root' | 'system' | 'block'
  final String kind;
  final RootPayloadSpec? root;
  final SystemPayloadSpec? system;
  final BlockPayloadSpec? block;

  const CustomPayloadEditorScreen({
    super.key,
    required this.kind,
    this.root,
    this.system,
    this.block,
  });

  @override
  State<CustomPayloadEditorScreen> createState() =>
      _CustomPayloadEditorScreenState();
}

class _CustomPayloadEditorScreenState extends State<CustomPayloadEditorScreen> {
  static const _iconPresets = <IconData>[
    Icons.widgets_outlined,
    Icons.public,
    Icons.dashboard_outlined,
    Icons.support_agent,
    Icons.insights_outlined,
    Icons.engineering_outlined,
    Icons.api_outlined,
    Icons.smartphone,
    Icons.login,
    Icons.payment_outlined,
    Icons.analytics_outlined,
    Icons.settings_outlined,
    Icons.description_outlined,
    Icons.notifications_active_outlined,
    Icons.dark_mode_outlined,
    Icons.translate_outlined,
    Icons.storefront_outlined,
    Icons.shield_outlined,
  ];

  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _folder;
  late final TextEditingController _libraries;
  late final TextEditingController _defaultLibrary;
  late final TextEditingController _markdown;
  late final TextEditingController _buildEnvLabel;
  late final TextEditingController _workflow;
  final List<_EnvDraft> _envDrafts = [];

  IconData _icon = Icons.widgets_outlined;
  final Set<String> _applicable = {};
  final List<PayloadParamDef> _params = [];
  String _buildEnv = 'flutter';

  bool get _isRoot => widget.kind == 'root';
  bool get _isSystem => widget.kind == 'system';

  @override
  void initState() {
    super.initState();
    final root = widget.root;
    final system = widget.system;
    final block = widget.block;
    _name = TextEditingController(
      text: root?.name ?? system?.name ?? block?.name ?? '',
    );
    _description = TextEditingController(
      text: root?.description ?? system?.description ?? block?.description ?? '',
    );
    _folder = TextEditingController(text: system?.defaultFolder ?? '');
    _libraries = TextEditingController(
        text: (system?.libraryOptions ?? const []).join(','));
    _defaultLibrary =
        TextEditingController(text: system?.defaultLibrary ?? 'ElementPlus');
    _markdown = TextEditingController(text: block?.markdownTemplate ?? '');
    _buildEnvLabel =
        TextEditingController(text: root?.buildEnvLabel ?? 'Flutter (stable)');
    _buildEnv = root?.buildEnv ?? 'flutter';
    _workflow = TextEditingController(
      text: (root?.workflowContent ?? '').trim().isEmpty
          ? '{{ENV}}\n${GitHubActionsTemplates.flutterBuildWorkflow}'
          : root!.workflowContent,
    );
    _icon = root?.icon ?? system?.icon ?? block?.icon ?? Icons.widgets_outlined;
    if (block != null) _applicable.addAll(block.applicableSystems);
    if (system != null) _params.addAll(system.extraParams);
    if (block != null) _params.addAll(block.params);
    if (root != null) {
      for (final env in root.envVars) {
        _envDrafts.add(_EnvDraft.fromEnv(env));
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _folder.dispose();
    _libraries.dispose();
    _defaultLibrary.dispose();
    _markdown.dispose();
    _buildEnvLabel.dispose();
    _workflow.dispose();
    for (final draft in _envDrafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写 Payload 名称')),
      );
      return;
    }
    if (_isRoot) {
      final keys = <String>{};
      final envVars = <RootEnvVar>[];
      for (final draft in _envDrafts) {
        final key = draft.key.text.trim().toUpperCase();
        if (key.isEmpty) continue;
        if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(key)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('环境变量名不合法：$key（仅支持大写字母/数字/下划线）')),
          );
          return;
        }
        if (!keys.add(key)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('环境变量名重复：$key')),
          );
          return;
        }
        envVars.add(
          RootEnvVar(
            key: key,
            value: draft.value.text,
            secret: draft.secret,
            description: draft.description.text.trim(),
          ),
        );
      }
      final workflow = _workflow.text.trim();
      if (workflow.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请填写 GitHub Actions workflow')),
        );
        return;
      }
      final spec = RootPayloadSpec(
        id: widget.root?.id ?? CustomPayloadService.newId('root'),
        name: name,
        description: _description.text.trim(),
        icon: _icon,
        buildEnv: _buildEnv,
        buildEnvLabel: _buildEnvLabel.text.trim().isEmpty
            ? _buildEnv
            : _buildEnvLabel.text.trim(),
        workflowContent: workflow,
        params: const [],
        envVars: envVars,
        isBuiltin: false,
      );
      await CustomPayloadService.instance.upsertRoot(spec);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Root Payload 已保存'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
      return;
    }
    if (_isSystem) {
      final spec = SystemPayloadSpec(
        id: widget.system?.id ??
            CustomPayloadService.newId('sys'),
        name: name,
        description: _description.text.trim(),
        icon: _icon,
        defaultFolder: _folder.text.trim().isEmpty
            ? 'system'
            : _folder.text.trim(),
        libraryOptions: _libraries.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        defaultLibrary: _defaultLibrary.text.trim().isEmpty
            ? 'ElementPlus'
            : _defaultLibrary.text.trim(),
        extraParams: List<PayloadParamDef>.unmodifiable(_params),
      );
      await CustomPayloadService.instance.upsertSystem(spec);
    } else {
      final spec = BlockPayloadSpec(
        id: widget.block?.id ?? CustomPayloadService.newId('blk'),
        name: name,
        description: _description.text.trim(),
        icon: _icon,
        applicableSystems: _applicable.toList(),
        params: List<PayloadParamDef>.unmodifiable(_params),
        markdownTemplate: _markdown.text.trim().isEmpty
            ? _defaultBlockTemplate(name)
            : _markdown.text,
      );
      await CustomPayloadService.instance.upsertBlock(spec);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_isSystem ? 'System' : 'Block'} Payload 已保存'),
        backgroundColor: Colors.green,
      ),
    );
    Navigator.of(context).pop(true);
  }

  String _defaultBlockTemplate(String name) => '''
# $name

> 由用户自定义的 Block Payload，AI 构建时请严格按本文件实现。

## 功能点

- 按「模块参数」中的取值实现功能
- 与所在 System Payload 的目录结构保持一致

## 模块参数

{{PARAMS_TABLE}}

## 验收标准

- 功能可运行、无报错
- 关键交互具备 loading 与失败兜底
''';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.root != null || widget.system != null || widget.block != null
              ? '编辑自定义 Payload'
              : '新建 ${_isRoot ? 'Root' : (_isSystem ? 'System' : 'Block')} Payload',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '例如：代理商后台 / 发票模块',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '描述',
              hintText: '一句话说明这个 Payload 解决什么问题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('图标', isDark),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final icon in _iconPresets)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _icon = icon),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _icon == icon
                          ? Colors.blueAccent.withValues(alpha: 0.18)
                          : (isDark
                              ? const Color(0xFF2D2D30)
                              : const Color(0xFFF5F7FA)),
                      border: Border.all(
                        color: _icon == icon
                            ? Colors.blueAccent
                            : Colors.transparent,
                      ),
                    ),
                    child: Icon(icon,
                        size: 20,
                        color: _icon == icon
                            ? Colors.blueAccent
                            : (isDark ? Colors.white70 : Colors.black54)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (_isRoot) ...[
            _sectionTitle('构建环境', isDark),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _buildEnv,
              decoration: const InputDecoration(
                labelText: '环境标识',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'flutter', child: Text('Flutter')),
                DropdownMenuItem(value: 'node', child: Text('Node.js')),
                DropdownMenuItem(value: 'custom', child: Text('自定义')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _buildEnv = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _buildEnvLabel,
              decoration: const InputDecoration(
                labelText: '环境展示名',
                hintText: '例如 Flutter (stable) / Node.js 20',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _sectionTitle('环境变量', isDark),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(
                    () => _envDrafts.add(_EnvDraft.empty()),
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加变量'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Secret 变量的值只写入 GitHub Secrets，不会出现在仓库文件里；'
              '普通变量会写入 workflow 与 .env.example。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
            const SizedBox(height: 8),
            if (_envDrafts.isEmpty)
              Text(
                '暂无环境变量',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              )
            else
              for (var i = 0; i < _envDrafts.length; i++)
                _buildEnvRow(i, isDark),
            const SizedBox(height: 18),
            _sectionTitle('GitHub Actions Workflow', isDark),
            const SizedBox(height: 4),
            Text(
              '可用 {{ENV}} 占位符插入全部环境变量；也可用 {{env.KEY}} 插入单个变量。'
              '未包含 {{ENV}} 时会自动在文件顶部追加 env 块。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _workflow,
              minLines: 14,
              maxLines: 28,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'name: SLIPE Build\non: ...\n{{ENV}}\njobs: ...',
                border: OutlineInputBorder(),
              ),
            ),
          ] else if (_isSystem) ...[
            _sectionTitle('System Payload 结构', isDark),
            const SizedBox(height: 8),
            TextField(
              controller: _folder,
              decoration: const InputDecoration(
                labelText: '默认目录名',
                hintText: '项目根目录下的文件夹名，例如 agent',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _libraries,
              decoration: const InputDecoration(
                labelText: '组件库选项',
                hintText: '英文逗号分隔，例如 ElementPlus,TDesign',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _defaultLibrary,
              decoration: const InputDecoration(
                labelText: '默认组件库',
                border: OutlineInputBorder(),
              ),
            ),
          ] else ...[
            _sectionTitle('适用端', isDark),
            const SizedBox(height: 4),
            Text('留空表示适用于所有 System Payload', style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black45,
            )),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final spec in SystemPayloadRegistry.all)
                  FilterChip(
                    label: Text(spec.name,
                        style: const TextStyle(fontSize: 12)),
                    selected: _applicable.contains(spec.id),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _applicable.add(spec.id);
                      } else {
                        _applicable.remove(spec.id);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _sectionTitle('模块文档（Markdown）', isDark),
            const SizedBox(height: 8),
            TextField(
              controller: _markdown,
              minLines: 10,
              maxLines: 20,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '留空将自动生成默认模板。可用 {{param_key}} 引用参数。',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (!_isRoot) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                _sectionTitle('参数定义', isDark),
                const Spacer(),
                TextButton.icon(
                  onPressed: _editParam,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加参数'),
                ),
              ],
            ),
            if (_params.isEmpty)
              Text('暂无参数；参数会出现在编排器的参数表单中',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black45))
            else
              for (var i = 0; i < _params.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    dense: true,
                    title: Text('${_params[i].label}（${_params[i].key}）',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '${_params[i].type.name}'
                      '${_params[i].defaultValue.isEmpty ? '' : ' · 默认 ${_params[i].defaultValue}'}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _editParam(index: i),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () =>
                              setState(() => _params.removeAt(i)),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildEnvRow(int index, bool isDark) {
    final draft = _envDrafts[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    controller: draft.key,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Key',
                      hintText: 'API_KEY',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    Switch(
                      value: draft.secret,
                      onChanged: (v) => setState(() => draft.secret = v),
                    ),
                    Text(
                      draft.secret ? 'Secret' : '明文',
                      style: TextStyle(
                        fontSize: 9,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() {
                    _envDrafts.removeAt(index).dispose();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.value,
              obscureText: draft.secret,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                labelText: 'Value',
                hintText: draft.secret ? '仅在 GitHub Secrets 中配置' : '例如 stable',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.description,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                labelText: '说明（可选）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, bool isDark) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      );

  Future<void> _editParam({int? index}) async {
    final existing = index == null ? null : _params[index];
    final key = TextEditingController(text: existing?.key ?? '');
    final label = TextEditingController(text: existing?.label ?? '');
    final hint = TextEditingController(text: existing?.hint ?? '');
    final defaultValue =
        TextEditingController(text: existing?.defaultValue ?? '');
    final options =
        TextEditingController(text: existing?.options.join(',') ?? '');
    var type = existing?.type ?? PayloadParamType.text;
    final result = await showDialog<PayloadParamDef>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加参数' : '编辑参数'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: key,
                  decoration: const InputDecoration(
                    labelText: '参数键（英文）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: label,
                  decoration: const InputDecoration(
                    labelText: '显示名称',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<PayloadParamType>(
                  initialValue: type,
                  decoration: const InputDecoration(
                    labelText: '类型',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: PayloadParamType.values
                      .map((t) => DropdownMenuItem(
                            value: t,
                            child: Text(t.name),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => type = v);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: defaultValue,
                  decoration: const InputDecoration(
                    labelText: '默认值',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: options,
                  decoration: const InputDecoration(
                    labelText: '可选项（英文逗号分隔，select 用）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: hint,
                  decoration: const InputDecoration(
                    labelText: '提示文案',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final k = key.text.trim();
                if (k.isEmpty) return;
                Navigator.pop(
                  dialogContext,
                  PayloadParamDef(
                    k,
                    label.text.trim().isEmpty ? k : label.text.trim(),
                    hint: hint.text.trim(),
                    defaultValue: defaultValue.text.trim(),
                    type: type,
                    options: options.text
                        .split(',')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList(),
                  ),
                );
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    key.dispose();
    label.dispose();
    hint.dispose();
    defaultValue.dispose();
    options.dispose();
    if (result == null) return;
    setState(() {
      if (index == null) {
        _params.add(result);
      } else {
        _params[index] = result;
      }
    });
  }
}

/// Root Payload 环境变量行的编辑状态
class _EnvDraft {
  final TextEditingController key;
  final TextEditingController value;
  final TextEditingController description;
  bool secret;

  _EnvDraft({
    required this.key,
    required this.value,
    required this.description,
    this.secret = false,
  });

  factory _EnvDraft.empty() => _EnvDraft(
        key: TextEditingController(),
        value: TextEditingController(),
        description: TextEditingController(),
      );

  factory _EnvDraft.fromEnv(RootEnvVar env) => _EnvDraft(
        key: TextEditingController(text: env.key),
        value: TextEditingController(text: env.value),
        description: TextEditingController(text: env.description),
        secret: env.secret,
      );

  void dispose() {
    key.dispose();
    value.dispose();
    description.dispose();
  }
}
