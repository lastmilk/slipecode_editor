import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../services/design_draft_service.dart';
import '../services/git_host.dart';
import '../services/loader_project_service.dart';
import 'design_draft_list_screen.dart';

/// 创建 Loader 项目
///
/// 仅支持「采用设计稿」方式：设计稿即完整 Vibe，
/// 引擎（[LoaderProjectService]）据此自动创建目录结构、
/// 项目必需文件与全部 .md 文本。
/// 如需编排，请先前往「设计稿」创建并保存。
class CreateLoaderProjectScreen extends StatefulWidget {
  /// 从设计稿列表进入时预选的设计稿
  final DesignDraft? initialDraft;

  const CreateLoaderProjectScreen({super.key, this.initialDraft});

  @override
  State<CreateLoaderProjectScreen> createState() =>
      _CreateLoaderProjectScreenState();
}

class _CreateLoaderProjectScreenState extends State<CreateLoaderProjectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _orgController = TextEditingController();
  final _repoNameController = TextEditingController();

  List<DesignDraft> _drafts = [];
  String? _selectedDraftId;

  bool _isCreating = false;
  bool _createRepo = false;

  /// 用户是否手动切换过建仓开关（含设计稿联动）；未切换时跟随偏好设置默认值
  bool _repoSwitchTouched = false;
  GitHost _host = GitHost.github;
  bool _repoNameEdited = false;

  /// 用户是否手动改过 Org；未改过时跟随项目名（com.example.<项目名>）
  bool _orgEdited = false;
  final List<String> _outputLines = [];

  /// 是否有任一 Git 平台已登录（决定远程仓库功能是否可用）
  bool get _anyHostSignedIn {
    return context.read<GitHubProvider>().isSignedIn ||
        context.read<GiteeProvider>().isSignedIn;
  }

  /// 实际生效的建仓开关：
  /// 未登录任何平台时强制关闭；未手动切换时跟随偏好设置
  bool get _effectiveCreateRepo {
    if (!_anyHostSignedIn) return false;
    if (_repoSwitchTouched) return _createRepo;
    return context.read<SettingsProvider>().settings.createRepoOnCreate;
  }

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>().settings;
    _host = settings.defaultGitHost;
    _createRepo = settings.createRepoOnCreate;
    _nameController.addListener(() {
      final name = _nameController.text.trim();
      if (!_repoNameEdited) {
        _repoNameController.text = name;
      }
      if (!_orgEdited) {
        _orgController.text = name.isEmpty ? 'com.example' : 'com.example.$name';
      }
    });
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    final items = await DesignDraftService.instance.list();
    if (!mounted) return;
    setState(() {
      _drafts = items;
      _selectedDraftId = widget.initialDraft?.id ??
          (items.isNotEmpty ? items.first.id : null);
    });
    _syncRepoDefaults();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _orgController.dispose();
    _repoNameController.dispose();
    super.dispose();
  }

  DesignDraft? get _selectedDraft {
    for (final d in _drafts) {
      if (d.id == _selectedDraftId) return d;
    }
    return null;
  }

  /// 空草稿兜底（仅用于无设计稿时的仓库默认值联动）
  DesignDraft get _fallbackDraft => DesignDraft(
        id: '_fallback_',
        name: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        root: RootPayloadInstance(specId: RootPayloadRegistry.all.first.id),
        systems: [],
      );

  /// 当前生效的设计稿
  DesignDraft get _activeDraft => _selectedDraft ?? _fallbackDraft;

  /// 按 Root Payload 的 git_host 参数联动仓库默认值
  void _syncRepoDefaults() {
    final rootParams = _activeDraft.root.params;
    final gitHost = rootParams['git_host'] ?? 'github';
    setState(() {
      // 设计稿明确指定了策略，视为已切换（不再跟随偏好默认值）
      _repoSwitchTouched = true;
      switch (gitHost) {
        case 'gitee':
          _host = GitHost.gitee;
          _createRepo = true;
        case 'none':
          _createRepo = false;
        default:
          _host = GitHost.github;
          _createRepo = true;
      }
    });
  }

  /// 项目固定存放在应用私有目录下（用户无需也无法更改）
  Future<String> _resolveTargetPath() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Projects', _nameController.text.trim());
  }

  String get _org {
    final org = _orgController.text.trim();
    return org.isEmpty ? 'com.example' : org;
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;

    final draft = _selectedDraft;
    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择或创建一个设计稿'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (draft.systems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('该设计稿还未编排任何 System Payload（端）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isCreating = true;
      _outputLines.clear();
    });

    final projectProvider = context.read<ProjectProvider>();
    final targetPath = await _resolveTargetPath();

    try {
      await for (final line in LoaderProjectService().createLoaderProject(
        projectName: _nameController.text.trim(),
        targetPath: targetPath,
        org: _org,
        draft: draft,
        root: draft.root,
        systems: draft.systems,
      )) {
        setState(() => _outputLines.add(line));
      }

      // 打开刚创建的项目（识别为 Loader 载荷）
      await projectProvider.openProject(targetPath, kind: 'loader');
      if (!mounted) return;

      // 创建远程仓库并推送骨架（需已登录对应平台）
      if (_effectiveCreateRepo) {
        final repoName = _repoNameController.text.trim().isEmpty
            ? _nameController.text.trim()
            : _repoNameController.text.trim();
        try {
          if (_host == GitHost.github) {
            final github = context.read<GitHubProvider>();
            if (github.isSignedIn) {
              await github.createRepoWithInitialPush(
                targetPath,
                repoName,
                onLog: (line) {
                  if (mounted) setState(() => _outputLines.add(line));
                },
              );
            } else {
              setState(() => _outputLines.add('未登录 GitHub，已跳过远程仓库创建'));
            }
          } else {
            final gitee = context.read<GiteeProvider>();
            if (gitee.isSignedIn) {
              await gitee.createRepoWithInitialPush(
                targetPath,
                repoName,
                onLog: (line) {
                  if (mounted) setState(() => _outputLines.add(line));
                },
              );
            } else {
              setState(() => _outputLines.add('未登录 Gitee，已跳过远程仓库创建'));
            }
          }
        } catch (e) {
          if (mounted) {
            setState(() => _outputLines.add('[ERROR] 远程仓库创建失败：$e'));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('项目已创建，但远程仓库创建失败：$e'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Loader 项目创建成功'),
            backgroundColor: Colors.green,
          ),
        );
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('创建 Loader 项目')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildBanner(isDark),
            const SizedBox(height: 16),
            _buildNameField(),
            const SizedBox(height: 16),
            _buildOrgField(),
            const SizedBox(height: 20),
            _buildDraftPicker(isDark),
            const SizedBox(height: 20),
            _buildRepoOptions(isDark),
            const SizedBox(height: 24),
            _buildCreateButton(),
            const SizedBox(height: 24),
            if (_outputLines.isNotEmpty) _buildLogs(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildBanner(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.blueAccent.withValues(alpha: 0.08)
            : const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.rocket_launch_outlined,
              size: 18, color: Colors.blueAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Loader 项目按「Root + System + Block」三层 Payload 组装生成。'
              '创建后进入编辑器 → 构建，先「AI 介入」让 Agent 无感完成代码，再「实际构建」出包。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameField() {
    return TextFormField(
      controller: _nameController,
      enabled: !_isCreating,
      decoration: const InputDecoration(
        labelText: '项目名称',
        hintText: 'my_loader_project',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.badge),
      ),
      textInputAction: TextInputAction.next,
      validator: (value) {
        if (value == null || value.isEmpty) return '请输入项目名称';
        if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value)) {
          return '以小写字母开头，仅含小写字母 / 数字 / 下划线';
        }
        return null;
      },
    );
  }

  /// Org（包名前缀）：默认跟随项目名 com.example.<项目名>，
  /// 用户手动修改后不再跟随
  Widget _buildOrgField() {
    return TextFormField(
      controller: _orgController,
      enabled: !_isCreating,
      onChanged: (value) {
        final name = _nameController.text.trim();
        final auto = name.isEmpty ? 'com.example' : 'com.example.$name';
        _orgEdited = value.trim().isNotEmpty && value.trim() != auto;
      },
      decoration: const InputDecoration(
        labelText: '组织标识（Org）',
        hintText: 'com.example.<项目名>',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.domain),
      ),
      textInputAction: TextInputAction.done,
      validator: (value) {
        final org = (value ?? '').trim();
        if (org.isEmpty) return null; // 空时回退 com.example
        if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$')
            .hasMatch(org)) {
          return '包名格式不正确（如 com.example.app）';
        }
        return null;
      },
    );
  }

  // --- 采用设计稿 -------------------------------------------------------------

  Widget _buildDraftPicker(bool isDark) {
    if (_drafts.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
          ),
        ),
        child: Column(
          children: [
            Text(
              '还没有保存过设计稿',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _openDraftManager,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('去创建设计稿'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final draft = _selectedDraft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _selectedDraftId,
                decoration: const InputDecoration(
                  labelText: '选择设计稿',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: _drafts
                    .map((d) => DropdownMenuItem(value: d.id, child: Text(d.name)))
                    .toList(),
                onChanged: _isCreating
                    ? null
                    : (id) {
                        setState(() => _selectedDraftId = id);
                        _syncRepoDefaults();
                      },
              ),
            ),
            IconButton(
              tooltip: '管理设计稿',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openDraftManager,
            ),
          ],
        ),
        if (draft != null) ...[
          const SizedBox(height: 10),
          _buildDraftPreview(draft, isDark),
        ],
      ],
    );
  }

  Future<void> _openDraftManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DesignDraftListScreen()),
    );
    await _loadDrafts();
  }

  /// 设计稿预览：Root + 各端 + Block 概览
  Widget _buildDraftPreview(DesignDraft draft, bool isDark) {
    final rootSpec = RootPayloadRegistry.byId(draft.root.specId);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(rootSpec.icon, size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${rootSpec.name} · ${rootSpec.buildEnvLabel}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${draft.systems.length} 个端',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ],
          ),
          if (draft.systems.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final sys in draft.systems) _buildSystemPreviewRow(sys, isDark),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '该设计稿尚未编排任何端',
                style: TextStyle(
                    fontSize: 11, color: Colors.orange[300]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSystemPreviewRow(SystemPayloadInstance sys, bool isDark) {
    final spec = SystemPayloadRegistry.byId(sys.specId);
    final library = sys.params['library'] ?? spec.defaultLibrary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(spec.icon, size: 14, color: Colors.teal),
          const SizedBox(width: 6),
          Text('${sys.folder}/',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${spec.name} · $library',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ),
          if (sys.blocks.isNotEmpty)
            Text(
              '${sys.blocks.length} 模块',
              style: TextStyle(
                fontSize: 10,
                color: Colors.orange[isDark ? 300 : 700],
              ),
            ),
        ],
      ),
    );
  }

  // --- 仓库选项（与创建传统项目一致） ------------------------------------------

  /// 未登录任何 Git 平台时，试图开启建仓功能 → 弹窗提醒配置账号
  void _showRepoLoginRequiredDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要配置 Git 平台账号'),
        content: const Text(
          '创建远程仓库需要登录 GitHub 或 Gitee 账号。\n'
          '请先在首页底部或账号页完成登录，再开启此功能。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildRepoOptions(bool isDark) {
    final github = context.watch<GitHubProvider>();
    final gitee = context.watch<GiteeProvider>();
    final signedInHosts = <GitHost>[
      if (github.isSignedIn) GitHost.github,
      if (gitee.isSignedIn) GitHost.gitee,
    ];
    final anySignedIn = signedInHosts.isNotEmpty;
    // 当前选中平台未登录时，自动切到已登录平台
    if (anySignedIn && !signedInHosts.contains(_host)) {
      _host = signedInHosts.first;
    }
    final effectiveCreateRepo = anySignedIn && _effectiveCreateRepo;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('创建远程仓库'),
            subtitle: Text(
              anySignedIn ? '创建后自动提交并推送项目骨架' : '未登录 GitHub / Gitee，默认关闭',
            ),
            value: effectiveCreateRepo,
            onChanged: _isCreating
                ? null
                : (value) {
                    if (value && !anySignedIn) {
                      _showRepoLoginRequiredDialog();
                      return;
                    }
                    setState(() {
                      _repoSwitchTouched = true;
                      _createRepo = value;
                    });
                  },
          ),
          if (effectiveCreateRepo) ...[
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Text('平台', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 12),
                  // 仅展示已登录的平台选项
                  ...signedInHosts.map(
                    (host) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(host.label),
                        selected: _host == host,
                        onSelected: _isCreating
                            ? null
                            : (_) => setState(() => _host = host),
                        selectedColor: Colors.blueAccent,
                        labelStyle: TextStyle(
                          fontSize: 12,
                          color: _host == host
                              ? Colors.white
                              : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _repoNameController,
              enabled: !_isCreating,
              onChanged: (_) => _repoNameEdited = true,
              decoration: InputDecoration(
                labelText: '仓库名',
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(Icons.cloud_outlined),
                suffixText: _host.label,
              ),
              validator: (value) {
                if (!_createRepo) return null;
                final name = (value == null || value.trim().isEmpty)
                    ? _nameController.text.trim()
                    : value.trim();
                if (name.isEmpty) return '请输入仓库名';
                if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
                  return '仓库名仅支持字母 / 数字 / . _ -';
                }
                return null;
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildCreateButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: _isCreating ? null : _create,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueAccent,
          foregroundColor: Colors.white,
        ),
        icon: _isCreating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.rocket_launch),
        label: Text(_isCreating ? '正在生成 Loader 项目…' : '生成 Loader 项目'),
      ),
    );
  }

  Widget _buildLogs(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '输出日志',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFDDDDDD),
            ),
          ),
          child: ListView.builder(
            reverse: true,
            itemCount: _outputLines.length,
            itemBuilder: (context, index) {
              final line = _outputLines[_outputLines.length - 1 - index];
              final isError = line.contains('[ERROR]');
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  line.trim(),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: isError
                        ? Colors.redAccent
                        : (isDark ? Colors.greenAccent : Colors.green[800]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
