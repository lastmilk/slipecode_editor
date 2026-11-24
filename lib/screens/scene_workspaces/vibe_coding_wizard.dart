import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/design_draft.dart';
import '../../payloads/loader/loader_payload.dart';
import '../../payloads/project_payload.dart';
import '../../providers/gitee_provider.dart';
import '../../providers/github_provider.dart';
import '../../providers/project_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/toolchain_provider.dart';
import '../../services/design_draft_service.dart';
import '../../services/desktop_platform.dart';
import '../../services/git_host.dart';
import '../../services/loader_project_service.dart';
import '../../services/project_agent_settings_service.dart';
import '../../services/project_create_service.dart';
import '../../services/toolchain/toolchain_environment.dart';
import '../../services/toolchain/toolchain_models.dart';
import '../../widgets/scene/glass_card.dart';
import '../../widgets/scene/scene_palette.dart';
import '../../widgets/scene/scene_tokens.dart';
import '../design_draft_editor_screen.dart';
import '../design_draft_list_screen.dart';

/// VibeCoding 的两种创建范式。
enum VibeCodingParadigm {
  /// 新范式：设计稿 + 三层 Payload + Loader 项目。
  newParadigm,

  /// 传统范式：内置模板直接起步。
  classic,
}

/// VibeCoding 创建向导。
///
/// 按场景体系（玻璃拟态分组卡片）重新实现两种范式的表单，
/// 业务逻辑与旧的创建页保持一致：目标路径、校验、仓库创建、
/// 工具链固定、Agent 隔离与逐行日志。
class VibeCodingWizard extends StatefulWidget {
  const VibeCodingWizard({
    super.key,
    required this.paradigm,
    required this.onCreated,
    this.onOpenDesignDrafts,
    this.initialDraftId,
  });

  final VibeCodingParadigm paradigm;

  /// 创建成功回调（参数为项目路径）。
  final ValueChanged<String> onCreated;

  /// 可选：由外部打开设计稿列表。
  final VoidCallback? onOpenDesignDrafts;

  /// 可选：进入时预选的设计稿（从「我的设计稿」直接创建时使用）。
  final String? initialDraftId;

  @override
  State<VibeCodingWizard> createState() => _VibeCodingWizardState();
}

class _VibeCodingWizardState extends State<VibeCodingWizard> {
  /// VibeCoding 强调色（深色文字保证按钮对比度）。
  static const Color _accent = Color(0xFF00F07A);
  static const Color _onAccent = Color(0xFF06120B);

  static const Color _successColor = Color(0xFF1F9D55);
  static const Color _warningColor = Color(0xFFE08A00);
  static const Color _errorColor = Color(0xFFD64545);

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _orgController = TextEditingController(text: 'com.example');
  final _repoNameController = TextEditingController();

  bool _isCreating = false;
  final List<String> _outputLines = [];

  // ---------------- 公共：仓库与 Agent ----------------

  /// 是否创建远程仓库并推送初始骨架。
  bool _createRepo = true;

  /// 目标 Git 平台。
  GitHost _host = GitHost.github;

  /// 用户是否手动改过仓库名；未改过时跟随项目名。
  bool _repoNameEdited = false;

  /// 用户是否手动改过包名；未改过时跟随项目名自动补全。
  bool _orgEdited = false;

  /// 是否开启 Agent 版本隔离（独立 MCP / Skills）。
  bool _agentIsolated = false;

  // ---------------- 传统范式 ----------------

  /// 当前选中的项目载荷。
  String _payloadId = PayloadRegistry.fallback.id;

  /// Flutter 模板（app / package / plugin）。
  String _template = 'app';

  /// Python：选择的解释器版本（空 = 系统 python3）。
  String _pythonVersion = '';

  /// Java：构建工具（gradle / maven）。
  String _javaBuildTool = 'gradle';

  /// C++：编译器（默认取本机第一个可用编译器）。
  String _cppCompiler =
      ToolchainEnvironment.availableCppCompilers().firstOrNull ??
      (DesktopPlatform.hostOs == 'windows' ? 'cl' : 'g++');

  /// C++：是否生成 Makefile（关闭则生成 CMakeLists.txt）。
  bool _cppUseMakefile = true;

  // ---------------- 新范式 ----------------

  List<DesignDraft> _drafts = [];
  String? _selectedDraftId;
  bool _draftLoading = true;

  bool get _isClassic => widget.paradigm == VibeCodingParadigm.classic;

  ProjectPayload get _payload => PayloadRegistry.byId(_payloadId);

  /// 可创建的项目载荷（排除仅用于识别 Loader 项目的载荷）。
  List<ProjectPayload> get _visiblePayloads =>
      PayloadRegistry.all.where((item) => !item.hiddenFromCreate).toList();

  /// 当前设计稿。
  DesignDraft? get _selectedDraft {
    for (final draft in _drafts) {
      if (draft.id == _selectedDraftId) return draft;
    }
    return null;
  }

  /// 空草稿兜底（仅用于仓库默认值联动）。
  DesignDraft get _fallbackDraft => DesignDraft(
    id: '_fallback_',
    name: '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    root: RootPayloadInstance(specId: RootPayloadRegistry.defaultId),
    systems: [],
  );

  DesignDraft get _activeDraft => _selectedDraft ?? _fallbackDraft;

  /// 载荷自定义选项（用于模板中的 {{KEY}} 替换）。
  Map<String, String> get _payloadOptions => switch (_payloadId) {
    'python' => {
      'PYTHON_VERSION': _pythonVersion.isEmpty ? '3.12' : _pythonVersion,
    },
    'java' => {'JAVA_BUILD_TOOL': _javaBuildTool},
    'cpp' => {
      'CPP_COMPILER': _cppCompiler,
      'CPP_USE_MAKEFILE': '$_cppUseMakefile',
    },
    _ => const {},
  };

  /// 实际使用的模板标识（Java 为构建工具，C++ 为 make / cmake）。
  String get _effectiveTemplate => switch (_payloadId) {
    'java' => _javaBuildTool,
    'cpp' => _cppUseMakefile ? 'make' : 'cmake',
    _ => _template,
  };

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>().settings;
    _host = settings.defaultGitHost;
    _createRepo = settings.createRepoOnCreate;

    // 仓库名与包名默认跟随项目名。
    _nameController.addListener(_onNameChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        // 两个平台都未登录时，默认关闭「创建远程仓库」。
        if (!_anyHostSignedIn()) _createRepo = false;
        _ensureHostAvailable();
      });
    });

    if (!_isClassic) _loadDrafts();
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _orgController.dispose();
    _repoNameController.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    final name = _nameController.text.trim();
    if (!_repoNameEdited) _repoNameController.text = name;
    if (!_orgEdited) {
      _orgController.text = name.isEmpty ? 'com.example' : 'com.example.$name';
    }
  }

  // ---------------------------------------------------------------------------
  // 账号 / 设计稿 / 路径
  // ---------------------------------------------------------------------------

  bool _hostSignedIn(GitHost host) => host == GitHost.github
      ? context.read<GitHubProvider>().isSignedIn
      : context.read<GiteeProvider>().isSignedIn;

  bool _anyHostSignedIn() =>
      _hostSignedIn(GitHost.github) || _hostSignedIn(GitHost.gitee);

  /// 当前选中的平台未登录时，回落到已登录平台。
  void _ensureHostAvailable() {
    if (_hostSignedIn(_host)) return;
    _host = GitHost.values.firstWhere(
      _hostSignedIn,
      orElse: () => GitHost.github,
    );
  }

  /// 提示需要先配置 GitHub / Gitee 账号。
  void _showNeedAccountDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要配置 Git 账号'),
        content: const Text(
          '创建远程仓库需要先在首页登录 GitHub 或 Gitee 账号。\n'
          '登录后即可创建并自动推送项目骨架。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t('common.confirm')),
          ),
        ],
      ),
    );
  }

  /// 由「包名」字段反推模板用的 org 前缀（去掉结尾的项目名段）。
  String _effectiveOrg() {
    final name = _nameController.text.trim();
    var org = _orgController.text.trim();
    if (name.isNotEmpty && org.toLowerCase().endsWith('.$name')) {
      org = org.substring(0, org.length - name.length - 1);
    }
    return org.isEmpty ? 'com.example' : org;
  }

  /// 项目固定保存在应用私有目录（无需任何存储权限）。
  Future<String> get _targetPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'Projects', _nameController.text.trim());
  }

  Future<void> _loadDrafts() async {
    final items = await DesignDraftService.instance.list();
    if (!mounted) return;
    final current = _selectedDraftId;
    final keep = items.any((draft) => draft.id == current);
    // 外部指定了设计稿且当前没有有效选择时，优先采用外部指定项。
    final preferred = widget.initialDraftId;
    final preferredValid =
        preferred != null && items.any((draft) => draft.id == preferred);
    setState(() {
      _drafts = items;
      _selectedDraftId = keep
          ? current
          : (preferredValid
                ? preferred
                : (items.isNotEmpty ? items.first.id : null));
      _draftLoading = false;
    });
    _syncRepoDefaults();
  }

  /// 按 Root Payload 的 git_host 参数联动仓库默认值。
  ///
  /// 仅在设计稿显式声明 git_host 时覆盖偏好设置，避免无 Root 的
  /// 社区设计稿把用户的建仓偏好重置。
  void _syncRepoDefaults() {
    final gitHost = _activeDraft.root.params['git_host'];
    setState(() {
      switch (gitHost) {
        case 'gitee':
          _host = GitHost.gitee;
          _createRepo = true;
        case 'none':
          _createRepo = false;
        case 'github':
          _host = GitHost.github;
          _createRepo = true;
      }
      // 登录态约束优先：未登录任何平台时强制关闭。
      if (_createRepo && !_anyHostSignedIn()) _createRepo = false;
      _ensureHostAvailable();
    });
  }

  Future<void> _openDraftManager() async {
    final external = widget.onOpenDesignDrafts;
    if (external != null) {
      external();
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const DesignDraftListScreen()));
    if (!mounted) return;
    await _loadDrafts();
  }

  Future<void> _openDraftEditor() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DesignDraftEditorScreen()));
    if (!mounted) return;
    await _loadDrafts();
  }

  // ---------------------------------------------------------------------------
  // 创建流程
  // ---------------------------------------------------------------------------

  Future<void> _createClassic() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isCreating = true;
      _outputLines.clear();
    });

    final createService = ProjectCreateService();
    final projectProvider = context.read<ProjectProvider>();
    final targetPath = await _targetPath;

    try {
      await for (final line in createService.createProject(
        payload: _payload,
        projectName: _nameController.text.trim(),
        targetPath: targetPath,
        org: _effectiveOrg(),
        template: _effectiveTemplate,
        options: _payloadOptions,
      )) {
        if (!mounted) return;
        setState(() => _outputLines.add(line));
      }

      await projectProvider.openProject(targetPath, kind: 'classic');

      // Python：把所选解释器版本固定到项目（写入项目级工具链选择）。
      if (_payloadId == 'python' && _pythonVersion.isNotEmpty && mounted) {
        context.read<ToolchainProvider>().pinProject(
          ToolchainKind.python,
          targetPath,
          _pythonVersion,
        );
      }
      await ProjectAgentSettingsService.instance.setIsolated(
        targetPath,
        _agentIsolated,
      );
      if (!mounted) return;

      await _createRemoteRepo(targetPath, classic: true);
      if (!mounted) return;

      _showSnack(t('create.success'), background: _successColor);
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      widget.onCreated(targetPath);
    } catch (e) {
      _showSnack(t('create.failed', {'error': '$e'}), background: _errorColor);
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  Future<void> _createLoader() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final draft = _selectedDraft;
    if (draft == null) {
      _showSnack('请先选择或创建一个设计稿', background: _warningColor);
      return;
    }
    if (draft.systems.isEmpty) {
      _showSnack('该设计稿还未编排任何 System Payload（端）', background: _warningColor);
      return;
    }

    setState(() {
      _isCreating = true;
      _outputLines.clear();
    });

    final projectProvider = context.read<ProjectProvider>();
    final targetPath = await _targetPath;
    if (!mounted) return;

    try {
      await for (final line in LoaderProjectService().createLoaderProject(
        projectName: _nameController.text.trim(),
        targetPath: targetPath,
        org: _effectiveOrg(),
        draft: draft,
        root: draft.root,
        systems: draft.systems,
      )) {
        if (!mounted) return;
        setState(() => _outputLines.add(line));
      }

      // 打开刚创建的项目（识别为 Loader 载荷）。
      await projectProvider.openProject(targetPath, kind: 'loader');
      await ProjectAgentSettingsService.instance.setIsolated(
        targetPath,
        _agentIsolated,
      );
      if (!mounted) return;

      await _createRemoteRepo(targetPath, classic: false);
      if (!mounted) return;

      _showSnack('Loader 项目创建成功', background: _successColor);
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      widget.onCreated(targetPath);
    } catch (e) {
      _showSnack('创建失败：$e', background: _errorColor);
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  /// 按所选平台创建仓库并推送骨架。
  ///
  /// 传统范式与新范式的日志文案略有差异，用 [classic] 区分。
  Future<void> _createRemoteRepo(
    String targetPath, {
    required bool classic,
  }) async {
    if (!_createRepo) return;
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
        } else if (mounted) {
          setState(
            () => _outputLines.add(
              classic
                  ? t('create.warnNotSignedInGithub')
                  : '未登录 GitHub，已跳过远程仓库创建',
            ),
          );
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
        } else if (mounted) {
          setState(
            () => _outputLines.add(
              classic
                  ? t('create.warnNotSignedInGitee')
                  : '未登录 Gitee，已跳过远程仓库创建',
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (classic) {
        final message = t('create.repoCreateFailed', {
          'host': _host.label,
          'error': '$e',
        });
        setState(() => _outputLines.add('[ERROR] $message'));
        _showSnack(
          t('create.projectCreatedButRepoFailed', {
            'host': _host.label,
            'error': '$e',
          }),
          background: _warningColor,
        );
      } else {
        setState(() => _outputLines.add('[ERROR] 远程仓库创建失败：$e'));
        _showSnack('项目已创建，但远程仓库创建失败：$e', background: _warningColor);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = ScenePalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final innerPadding = narrow ? 14.0 : 20.0;
    final groups = _isClassic
        ? _buildClassicGroups(palette, narrow, innerPadding)
        : _buildLoaderGroups(palette, narrow, innerPadding);

    return Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          for (final group in groups) ...[
            group,
            const SizedBox(height: SceneTokens.gap),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildClassicGroups(
    ScenePalette palette,
    bool narrow,
    double innerPadding,
  ) {
    final groups = <Widget>[
      _group(
        palette,
        icon: Icons.badge_outlined,
        title: '基础信息',
        description: '传统范式直接使用内置模板生成标准工程骨架，可立即在编辑器中打开。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _input(
              palette,
              label: t('create.projectName'),
              hint: _payload.projectNameHint,
              icon: Icons.badge_outlined,
              controller: _nameController,
              action: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return t('create.nameRequired');
                }
                if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value)) {
                  return t('create.nameInvalid');
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            _input(
              palette,
              label: '包名',
              hint:
                  'com.example.${_nameController.text.trim().isEmpty ? 'myapp' : _nameController.text.trim()}',
              icon: Icons.domain_outlined,
              controller: _orgController,
              action: TextInputAction.next,
              onChanged: (_) => _orgEdited = true,
            ),
          ],
        ),
      ),
      _group(
        palette,
        icon: Icons.widgets_outlined,
        title: '项目类型',
        description: '选择内置载荷；不同类型对应不同的目录结构、语言高亮与云端构建方式。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _optionRow([
              for (final payload in _visiblePayloads)
                _optionCard(
                  palette,
                  label: payload.name,
                  icon: payload.icon,
                  selected: _payloadId == payload.id,
                  onTap: () => _selectPayload(payload),
                ),
            ], narrow: narrow),
            const SizedBox(height: 10),
            Text(
              _payload.description,
              style: SceneTokens.sceneCaption(
                11.5,
                color: palette.textTertiary,
              ),
            ),
          ],
        ),
      ),
    ];

    if (_payload.isFlutter) {
      groups.add(
        _group(
          palette,
          icon: Icons.layers_outlined,
          title: 'Flutter 模板',
          description: '应用、包、插件对应不同的工程入口与发布方式。',
          padding: innerPadding,
          child: _optionRow([
            _optionCard(
              palette,
              label: t('create.templateApp'),
              icon: Icons.apps_rounded,
              selected: _template == 'app',
              onTap: () => setState(() => _template = 'app'),
            ),
            _optionCard(
              palette,
              label: t('create.templatePackage'),
              icon: Icons.inventory_2_outlined,
              selected: _template == 'package',
              onTap: () => setState(() => _template = 'package'),
            ),
            _optionCard(
              palette,
              label: t('create.templatePlugin'),
              icon: Icons.extension_outlined,
              selected: _template == 'plugin',
              onTap: () => setState(() => _template = 'plugin'),
            ),
          ], narrow: narrow),
        ),
      );
    }

    final toolchain = _buildClassicToolchain(palette, narrow, innerPadding);
    if (toolchain != null) groups.add(toolchain);

    groups.addAll([
      _group(
        palette,
        icon: Icons.cloud_outlined,
        title: '远程仓库',
        description: '登录 GitHub / Gitee 后可在创建时自动建仓并推送初始骨架。',
        padding: innerPadding,
        child: _buildRepoOptions(palette, narrow),
      ),
      _group(
        palette,
        icon: Icons.shield_outlined,
        title: 'Agent 设置',
        description: '开启隔离后，本项目使用独立的 MCP / Skills，不会与其它项目共享。',
        padding: innerPadding,
        child: _switchRow(
          palette,
          title: 'Agent 版本隔离',
          subtitle: '开启后该项目使用独立的 MCP / Skills 配置（不会与其它项目共享）',
          value: _agentIsolated,
          onChanged: (value) => setState(() => _agentIsolated = value),
        ),
      ),
      _group(
        palette,
        icon: Icons.rocket_launch_outlined,
        title: '创建',
        description: '创建过程会实时输出日志；完成后自动打开项目并关闭工作台。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _createButton(label: t('create.submit'), onCreate: _createClassic),
            if (_outputLines.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildLogs(palette),
            ],
          ],
        ),
      ),
    ]);
    return groups;
  }

  /// 载荷专属选项（Python 版本 / Java 构建工具 / C++ 编译器与 Makefile）。
  Widget? _buildClassicToolchain(
    ScenePalette palette,
    bool narrow,
    double innerPadding,
  ) {
    if (_payloadId == 'python') {
      final toolchain = context.watch<ToolchainProvider>();
      final installed = toolchain
          .installedOf(ToolchainKind.python)
          .map((item) => item.version)
          .toList();
      return _group(
        palette,
        icon: Icons.terminal_rounded,
        title: 'Python 解释器',
        description: '托管版本可在「设置 → 工具链」中安装；不选则使用系统 python3。',
        padding: innerPadding,
        child: _optionRow([
          _optionCard(
            palette,
            label: '系统 python3',
            icon: Icons.computer_rounded,
            selected: _pythonVersion.isEmpty,
            onTap: () => setState(() => _pythonVersion = ''),
          ),
          for (final version in installed)
            _optionCard(
              palette,
              label: 'Python $version',
              icon: Icons.terminal_rounded,
              selected: _pythonVersion == version,
              onTap: () => setState(() => _pythonVersion = version),
            ),
        ], narrow: narrow),
      );
    }

    if (_payloadId == 'java') {
      return _group(
        palette,
        icon: Icons.build_outlined,
        title: '构建工具',
        description: '生成对应构建工具的工程文件，云端构建会使用相同的工具链。',
        padding: innerPadding,
        child: _optionRow([
          _optionCard(
            palette,
            label: 'Gradle',
            icon: Icons.account_tree_outlined,
            selected: _javaBuildTool == 'gradle',
            onTap: () => setState(() => _javaBuildTool = 'gradle'),
          ),
          _optionCard(
            palette,
            label: 'Maven',
            icon: Icons.account_tree_rounded,
            selected: _javaBuildTool == 'maven',
            onTap: () => setState(() => _javaBuildTool = 'maven'),
          ),
        ], narrow: narrow),
      );
    }

    if (_payloadId == 'cpp') {
      final compilers = ToolchainEnvironment.availableCppCompilers();
      final options = compilers.isEmpty ? [_cppCompiler] : compilers;
      final current = options.contains(_cppCompiler)
          ? _cppCompiler
          : options.first;
      return _group(
        palette,
        icon: Icons.memory_rounded,
        title: 'C++ 工具链',
        description: '仅列出本机已安装的编译器；Makefile 与 CMakeLists.txt 二选一生成。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _optionRow([
              for (final compiler in options)
                _optionCard(
                  palette,
                  label: compiler,
                  icon: Icons.memory_rounded,
                  selected: current == compiler,
                  onTap: () => setState(() => _cppCompiler = compiler),
                ),
            ], narrow: narrow),
            const SizedBox(height: 14),
            _switchRow(
              palette,
              title: '启用 Makefile',
              subtitle: '开启生成 Makefile；关闭则生成 CMakeLists.txt',
              value: _cppUseMakefile,
              onChanged: (value) => setState(() => _cppUseMakefile = value),
            ),
          ],
        ),
      );
    }

    return null;
  }

  List<Widget> _buildLoaderGroups(
    ScenePalette palette,
    bool narrow,
    double innerPadding,
  ) {
    return [
      _group(
        palette,
        icon: Icons.auto_awesome_rounded,
        title: '基础信息',
        description: '新范式以设计稿为完整 Vibe，按 Root + System + Block 三层 Payload 生成项目。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _input(
              palette,
              label: '项目名称',
              hint: 'my_loader_project',
              icon: Icons.badge_outlined,
              controller: _nameController,
              action: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入项目名称';
                if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value)) {
                  return '以小写字母开头，仅含小写字母 / 数字 / 下划线';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            _input(
              palette,
              label: '包名',
              hint: 'com.example.myapp',
              icon: Icons.domain_outlined,
              controller: _orgController,
              action: TextInputAction.done,
              onChanged: (_) => _orgEdited = true,
            ),
          ],
        ),
      ),
      _group(
        palette,
        icon: Icons.design_services_outlined,
        title: '设计稿',
        description: '选择一份已保存的设计稿；创建时会生成各端目录、SYSTEM.md 与 blocks/*.md。',
        padding: innerPadding,
        child: _buildDraftSection(palette),
      ),
      _group(
        palette,
        icon: Icons.cloud_outlined,
        title: '远程仓库',
        description: '登录 GitHub / Gitee 后可在创建时自动建仓并推送初始骨架。',
        padding: innerPadding,
        child: _buildRepoOptions(palette, narrow),
      ),
      _group(
        palette,
        icon: Icons.shield_outlined,
        title: 'Agent 设置',
        description: '开启隔离后，本项目使用独立的 MCP / Skills，不会与其它项目共享。',
        padding: innerPadding,
        child: _switchRow(
          palette,
          title: 'Agent 版本隔离',
          subtitle: '开启后该项目使用独立的 MCP / Skills 配置（不会与其它项目共享）',
          value: _agentIsolated,
          onChanged: (value) => setState(() => _agentIsolated = value),
        ),
      ),
      _group(
        palette,
        icon: Icons.rocket_launch_outlined,
        title: '创建',
        description: '生成过程中会实时输出日志；完成后自动打开 Loader 项目并关闭工作台。',
        padding: innerPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _createButton(label: '生成 Loader 项目', onCreate: _createLoader),
            if (_outputLines.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildLogs(palette),
            ],
          ],
        ),
      ),
    ];
  }

  // ---------------- 设计稿 ----------------

  Widget _buildDraftSection(ScenePalette palette) {
    if (_draftLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
          ),
        ),
      );
    }

    if (_drafts.isEmpty) {
      return _buildEmptyDrafts(palette);
    }

    final draft = _selectedDraft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in _drafts) _buildDraftCard(item, palette),
        if (draft != null) ...[
          const SizedBox(height: 4),
          _buildDraftPreview(draft, palette),
        ],
        const SizedBox(height: 12),
        _buildDraftActions(palette),
      ],
    );
  }

  Widget _buildEmptyDrafts(ScenePalette palette) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.inputFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.design_services_outlined,
                size: 18,
                color: palette.textTertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '还没有保存过设计稿',
                  style: SceneTokens.sceneBody(
                    13,
                    color: palette.textSecondary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '新范式需要先编排 Root / System / Block，再回来创建 Loader 项目。',
            style: SceneTokens.sceneCaption(11.5, color: palette.textTertiary),
          ),
          const SizedBox(height: 12),
          _buildDraftActions(palette),
        ],
      ),
    );
  }

  Widget _buildDraftActions(ScenePalette palette) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _isCreating ? null : _openDraftEditor,
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('新建设计稿'),
        ),
        OutlinedButton.icon(
          onPressed: _isCreating ? null : _openDraftManager,
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.textSecondary,
            side: BorderSide(color: palette.glassBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.tune_rounded, size: 16),
          label: const Text('管理设计稿'),
        ),
      ],
    );
  }

  Widget _buildDraftCard(DesignDraft draft, ScenePalette palette) {
    final selected = draft.id == _selectedDraftId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _isCreating
              ? null
              : () {
                  setState(() => _selectedDraftId = draft.id);
                  _syncRepoDefaults();
                },
          child: AnimatedContainer(
            duration: SceneTokens.durationFast,
            curve: SceneTokens.curve,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? _accent.withValues(alpha: palette.isDark ? 0.14 : 0.10)
                  : palette.inputFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? _accent : palette.glassBorder,
                width: selected ? 1.2 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? _accent.withValues(alpha: 0.16)
                        : palette.glassFillStrong,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.design_services_outlined,
                    size: 18,
                    color: selected ? _accent : palette.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        draft.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SceneTokens.sceneBody(
                          13.5,
                          color: palette.textPrimary,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${draft.systems.length} 个端 · ${_formatTime(draft.updatedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SceneTokens.sceneCaption(
                          11,
                          color: palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 18, color: _accent)
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: palette.textTertiary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设计稿预览：Root + 各端 + Block 概览。
  Widget _buildDraftPreview(DesignDraft draft, ScenePalette palette) {
    final rootSpec = RootPayloadRegistry.byId(draft.root.specId);
    final rootLabel = rootSpec.buildEnvLabel.isEmpty
        ? rootSpec.name
        : '${rootSpec.name} · ${rootSpec.buildEnvLabel}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.glassFillStrong,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(rootSpec.icon, size: 16, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rootLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SceneTokens.sceneBody(
                    12,
                    color: palette.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${draft.systems.length} 个端',
                style: SceneTokens.sceneCaption(
                  11,
                  color: palette.textTertiary,
                ),
              ),
            ],
          ),
          if (draft.systems.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final system in draft.systems)
              _buildSystemPreviewRow(system, palette),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '该设计稿尚未编排任何端',
                style: SceneTokens.sceneCaption(
                  11,
                  color: palette.isDark
                      ? const Color(0xFFFFB74D)
                      : const Color(0xFFB26A00),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSystemPreviewRow(
    SystemPayloadInstance system,
    ScenePalette palette,
  ) {
    final spec = SystemPayloadRegistry.byId(system.specId);
    final library = system.params['library'] ?? spec.defaultLibrary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(spec.icon, size: 14, color: palette.textTertiary),
          const SizedBox(width: 6),
          Text(
            '${system.folder}/',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: palette.codeForeground,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${spec.name} · $library',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SceneTokens.sceneCaption(11, color: palette.textSecondary),
            ),
          ),
          if (system.blocks.isNotEmpty)
            Text(
              '${system.blocks.length} 模块',
              style: SceneTokens.sceneCaption(
                10,
                color: palette.isDark
                    ? const Color(0xFFFFB74D)
                    : const Color(0xFFB26A00),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 仓库 ----------------

  Widget _buildRepoOptions(ScenePalette palette, bool narrow) {
    // 登录态变化时联动可选平台，仅展示已登录的平台。
    final githubSignedIn = context.watch<GitHubProvider>().isSignedIn;
    final giteeSignedIn = context.watch<GiteeProvider>().isSignedIn;
    final availableHosts = <GitHost>[
      if (githubSignedIn) GitHost.github,
      if (giteeSignedIn) GitHost.gitee,
    ];
    if (_createRepo && availableHosts.isNotEmpty && !_hostSignedIn(_host)) {
      _host = availableHosts.first;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _switchRow(
          palette,
          title: t('create.repoSwitchTitle'),
          subtitle: availableHosts.isEmpty
              ? '需要先在首页登录 GitHub 或 Gitee 账号'
              : t('create.repoSwitchSubtitle'),
          value: _createRepo,
          onChanged: (value) {
            // 未登录任何平台时不允许开启，并弹窗引导配置账号。
            if (value && availableHosts.isEmpty) {
              _showNeedAccountDialog();
              return;
            }
            setState(() => _createRepo = value);
          },
        ),
        if (_createRepo) ...[
          const SizedBox(height: 14),
          Divider(height: 1, color: palette.divider),
          const SizedBox(height: 14),
          Text(
            t('create.platform'),
            style: SceneTokens.sceneBody(
              12.5,
              color: palette.textSecondary,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (availableHosts.isEmpty)
            Text(
              '未登录任何 Git 平台，创建后将不会推送远程仓库。',
              style: SceneTokens.sceneCaption(
                11.5,
                color: palette.textTertiary,
              ),
            )
          else
            _optionRow([
              for (final host in availableHosts)
                _optionCard(
                  palette,
                  label: host.label,
                  icon: host == GitHost.github
                      ? Icons.code_rounded
                      : Icons.hub_outlined,
                  selected: _host == host,
                  onTap: () => setState(() => _host = host),
                ),
            ], narrow: narrow),
          const SizedBox(height: 14),
          _input(
            palette,
            label: t('create.repoNameLabel'),
            hint: t('create.repoNameHint'),
            icon: Icons.cloud_outlined,
            suffixText: _host.label,
            controller: _repoNameController,
            onChanged: (_) => _repoNameEdited = true,
            validator: (value) {
              if (!_createRepo) return null;
              final name = (value == null || value.trim().isEmpty)
                  ? _nameController.text.trim()
                  : value.trim();
              if (name.isEmpty) return t('create.repoNameRequired');
              if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
                return t('create.repoNameInvalid');
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 13,
                color: palette.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _host == GitHost.gitee
                      ? t('create.repoHintGitee')
                      : t('create.repoHintGithub'),
                  style: SceneTokens.sceneCaption(
                    10.5,
                    color: palette.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------- 基础组件 ----------------

  Widget _group(
    ScenePalette palette, {
    required IconData icon,
    required String title,
    required String description,
    required Widget child,
    required double padding,
  }) {
    return GlassCard(
      radius: SceneTokens.radiusSmall,
      glow: false,
      enableHoverScale: false,
      padding: EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: _accent.withValues(
                    alpha: palette.isDark ? 0.14 : 0.10,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 16, color: _accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: SceneTokens.sceneBody(
                    14,
                    color: palette.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: SceneTokens.sceneCaption(11.5, color: palette.textTertiary),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  /// 统一样式的输入框：填充、12 圆角、聚焦 accent 描边。
  Widget _input(
    ScenePalette palette, {
    required String label,
    required TextEditingController controller,
    String? hint,
    IconData? icon,
    String? suffixText,
    TextInputAction? action,
    bool enabled = true,
    ValueChanged<String>? onChanged,
    String? Function(String?)? validator,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: palette.glassBorder),
    );
    final focused = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _accent, width: 1.4),
    );
    final errorBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _errorColor.withValues(alpha: 0.7)),
    );

    return TextFormField(
      controller: controller,
      enabled: enabled && !_isCreating,
      onChanged: onChanged,
      validator: validator,
      textInputAction: action,
      cursorColor: _accent,
      style: SceneTokens.sceneBody(13.5, color: palette.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: SceneTokens.sceneBody(13, color: palette.textSecondary),
        floatingLabelStyle: SceneTokens.sceneBody(
          12.5,
          color: _accent,
          weight: FontWeight.w600,
        ),
        hintText: hint,
        hintStyle: SceneTokens.sceneCaption(12, color: palette.textTertiary),
        prefixIcon: icon == null
            ? null
            : Icon(icon, size: 18, color: palette.textSecondary),
        suffixText: suffixText,
        suffixStyle: SceneTokens.sceneCaption(
          11.5,
          color: palette.textTertiary,
        ),
        filled: true,
        fillColor: palette.inputFill,
        constraints: const BoxConstraints(minHeight: 50),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: border,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: focused,
        errorBorder: errorBorder,
        focusedErrorBorder: errorBorder,
        errorStyle: SceneTokens.sceneCaption(11, color: _errorColor),
      ),
    );
  }

  /// 选项行：移动端横向滚动，宽屏自动换行。
  Widget _optionRow(List<Widget> children, {required bool narrow}) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (narrow) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              children[i],
            ],
          ],
        ),
      );
    }
    return Wrap(spacing: 10, runSpacing: 10, children: children);
  }

  /// 可点大卡 / 胶囊：选中态 accent 描边 + 填充 + 勾选。
  Widget _optionCard(
    ScenePalette palette, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _isCreating ? null : onTap,
        child: AnimatedContainer(
          duration: SceneTokens.durationFast,
          curve: SceneTokens.curve,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? _accent.withValues(alpha: palette.isDark ? 0.14 : 0.10)
                : palette.inputFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _accent : palette.glassBorder,
              width: selected ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 17,
                  color: selected ? _accent : palette.textSecondary,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: SceneTokens.sceneBody(
                  12.5,
                  color: selected ? palette.textPrimary : palette.textSecondary,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_rounded, size: 16, color: _accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _switchRow(
    ScenePalette palette, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: SceneTokens.sceneBody(
                  13,
                  color: palette.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: SceneTokens.sceneCaption(
                  11,
                  color: palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch.adaptive(
          value: value,
          onChanged: _isCreating ? null : onChanged,
          activeThumbColor: _accent,
          activeTrackColor: _accent.withValues(alpha: 0.35),
          inactiveThumbColor: palette.textTertiary,
          inactiveTrackColor: palette.divider,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _createButton({
    required String label,
    required VoidCallback onCreate,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: _isCreating ? null : onCreate,
        style: FilledButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: _onAccent,
          disabledBackgroundColor: _accent.withValues(alpha: 0.45),
          disabledForegroundColor: _onAccent.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: _isCreating
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _onAccent.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text('创建中…'),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.rocket_launch_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(label),
                ],
              ),
      ),
    );
  }

  Widget _buildLogs(ScenePalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('create.outputLogs'),
          style: SceneTokens.sceneBody(
            12.5,
            color: palette.textSecondary,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: palette.codeBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.glassBorder),
          ),
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: _outputLines.length,
            itemBuilder: (context, index) {
              final line = _outputLines[_outputLines.length - 1 - index];
              final isError = line.contains('[ERROR]');
              final isWarning = line.contains('[WARN]');
              final Color color;
              if (isError) {
                color = palette.isDark
                    ? const Color(0xFFFF7A8A)
                    : const Color(0xFFC62828);
              } else if (isWarning) {
                color = palette.isDark
                    ? const Color(0xFFFFCC80)
                    : const Color(0xFFE65100);
              } else {
                color = palette.isDark
                    ? const Color(0xFF7DFFA8)
                    : const Color(0xFF1B7F3B);
              }
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Text(
                  line.trim(),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: color,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 新样式浮层提示。
  void _showSnack(String message, {Color? background}) {
    if (!mounted) return;
    final palette = ScenePalette.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        backgroundColor:
            background ??
            (palette.isDark ? const Color(0xFF1C1C22) : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.glassBorder),
        ),
        content: Text(
          message,
          style: SceneTokens.sceneBody(
            12.5,
            color: background != null ? Colors.white : palette.textPrimary,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// 选择载荷时重置该载荷的默认模板。
  void _selectPayload(ProjectPayload payload) {
    setState(() {
      _payloadId = payload.id;
      _template = switch (payload.id) {
        'java' => 'gradle',
        'cpp' => 'make',
        _ => 'app',
      };
    });
  }

  static String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}
