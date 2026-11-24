import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/toolchain_provider.dart';
import '../l10n/app_localizations.dart';
import '../payloads/project_payload.dart';
import '../services/desktop_platform.dart';
import '../services/git_host.dart';
import '../services/project_agent_settings_service.dart';
import '../services/project_create_service.dart';
import '../services/toolchain/toolchain_environment.dart';
import '../services/toolchain/toolchain_models.dart';

/// 创建新项目页面
class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({super.key, this.embedded = false, this.onCreated});

  /// 是否以内嵌形式渲染（不带 Scaffold / AppBar），用于 VibeCoding 工作台。
  final bool embedded;

  /// 内嵌模式下的创建成功回调（参数为项目路径）。
  final ValueChanged<String>? onCreated;

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _orgController = TextEditingController(text: 'com.example');
  final _repoNameController = TextEditingController();

  String _template = 'app';
  bool _isCreating = false;

  /// 当前选中的项目载荷（决定模板、高亮与 GitHub Actions）
  String _payloadId = PayloadRegistry.fallback.id;

  ProjectPayload get _payload => PayloadRegistry.byId(_payloadId);

  /// 是否创建远程仓库并推送模板文件
  bool _createRepo = true;

  /// 目标 Git 平台（默认 GitHub）
  GitHost _host = GitHost.github;

  /// 用户是否手动改过仓库名；未改过时跟随项目名
  bool _repoNameEdited = false;

  /// 用户是否手动改过包名；未改过时跟随项目名自动补全为 com.example.<name>
  bool _orgEdited = false;

  /// 是否开启 Agent 版本隔离（独立 MCP / Skills）
  bool _agentIsolated = false;

  /// Python：选择的解释器版本（空 = 使用系统 python3）
  String _pythonVersion = '';

  /// Java：构建工具（gradle / maven）
  String _javaBuildTool = 'gradle';

  /// C++：编译器（默认取本机第一个可用编译器）
  String _cppCompiler =
      ToolchainEnvironment.availableCppCompilers().firstOrNull ??
      (DesktopPlatform.hostOs == 'windows' ? 'cl' : 'g++');

  /// C++：是否生成 Makefile（关闭则生成 CMakeLists.txt）
  bool _cppUseMakefile = true;

  /// 载荷自定义选项（用于模板中的 {{KEY}} 替换）
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

  /// 切换模板：各载荷的默认 template（Flutter=app、Java=gradle、C++=make）
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

  final List<String> _outputLines = [];

  @override
  void initState() {
    super.initState();
    // 项目固定保存在应用私有目录（无需任何存储权限，用户无需选择路径）。
    final settings = context.read<SettingsProvider>().settings;

    // 偏好设置中的默认 Git 平台与建仓开关
    _host = settings.defaultGitHost;
    _createRepo = settings.createRepoOnCreate;

    // 仓库名与包名默认跟随项目名
    _nameController.addListener(() {
      final name = _nameController.text.trim();
      if (!_repoNameEdited) {
        _repoNameController.text = name;
      }
      if (!_orgEdited) {
        _orgController.text = name.isEmpty
            ? 'com.example'
            : 'com.example.$name';
      }
    });

    // 两个平台都未登录时，默认关闭「创建远程仓库」
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_anyHostSignedIn()) {
        setState(() => _createRepo = false);
      }
      _ensureHostAvailable();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _orgController.dispose();
    _repoNameController.dispose();
    super.dispose();
  }

  bool _hostSignedIn(GitHost host) => host == GitHost.github
      ? context.read<GitHubProvider>().isSignedIn
      : context.read<GiteeProvider>().isSignedIn;

  bool _anyHostSignedIn() =>
      _hostSignedIn(GitHost.github) || _hostSignedIn(GitHost.gitee);

  /// 当前选中的平台未登录时，回落到已登录平台
  void _ensureHostAvailable() {
    if (!_hostSignedIn(_host)) {
      final fallback = GitHost.values.firstWhere(
        _hostSignedIn,
        orElse: () => GitHost.github,
      );
      setState(() => _host = fallback);
    }
  }

  /// 提示需要先配置 GitHub / Gitee 账号
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

  /// 由「包名」字段反推模板用的 org 前缀（去掉结尾的项目名段）
  String _effectiveOrg() {
    final name = _nameController.text.trim();
    var org = _orgController.text.trim();
    if (name.isNotEmpty && org.toLowerCase().endsWith('.$name')) {
      org = org.substring(0, org.length - name.length - 1);
    }
    return org.isEmpty ? 'com.example' : org;
  }

  Future<String> get _targetPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'Projects', _nameController.text.trim());
  }

  /// 实际使用的模板标识（Java 为构建工具，C++ 为 make / cmake）
  String get _effectiveTemplate => switch (_payloadId) {
    'java' => _javaBuildTool,
    'cpp' => _cppUseMakefile ? 'make' : 'cmake',
    _ => _template,
  };

  Future<void> _createProject() async {
    if (!_formKey.currentState!.validate()) return;

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
        setState(() {
          _outputLines.add(line);
        });
      }

      // 打开刚创建的项目
      await projectProvider.openProject(targetPath, kind: 'classic');

      // Python：把所选解释器版本固定到项目（写入项目级工具链选择）
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

      // 按所选平台创建仓库并推送模板文件
      if (_createRepo) {
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
              if (mounted) {
                setState(
                  () => _outputLines.add(t('create.warnNotSignedInGithub')),
                );
              }
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
              if (mounted) {
                setState(
                  () => _outputLines.add(t('create.warnNotSignedInGitee')),
                );
              }
            }
          }
        } catch (e) {
          if (mounted) {
            final message = t('create.repoCreateFailed', {
              'host': _host.label,
              'error': '$e',
            });
            setState(() => _outputLines.add('[ERROR] $message'));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  t('create.projectCreatedButRepoFailed', {
                    'host': _host.label,
                    'error': '$e',
                  }),
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }

      if (mounted) {
        // 先显示完成，再跳转到编辑器
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('create.success')),
            backgroundColor: Colors.green,
          ),
        );
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        if (widget.embedded) {
          widget.onCreated?.call(targetPath);
        } else {
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('create.failed', {'error': '$e'})),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 桌面 / 宽屏：左侧配置 + 右侧项目类型列表
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final content = Form(
      key: _formKey,
      child: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildConfigForm(isDark, showPayloadSelector: false),
                ),
                const VerticalDivider(width: 1),
                SizedBox(width: 320, child: _buildTypeList(isDark)),
              ],
            )
          : _buildConfigForm(isDark, showPayloadSelector: true),
    );

    // 内嵌模式：只返回表单本体，由外层工作台提供外壳与导航。
    if (widget.embedded) return content;

    return Scaffold(
      appBar: AppBar(title: Text(t('create.title')), elevation: 0),
      body: content,
    );
  }

  /// 配置表单（窄屏时包含项目类型选择条）
  Widget _buildConfigForm(bool isDark, {required bool showPayloadSelector}) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 项目名称
        TextFormField(
          controller: _nameController,
          enabled: !_isCreating,
          decoration: InputDecoration(
            labelText: t('create.projectName'),
            hintText: _payload.projectNameHint,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.badge),
          ),
          textInputAction: TextInputAction.next,
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
        const SizedBox(height: 16),

        // 包名（未手动修改时跟随项目名自动补全为 com.example.<name>）
        TextFormField(
          controller: _orgController,
          enabled: !_isCreating,
          onChanged: (_) => _orgEdited = true,
          decoration: InputDecoration(
            labelText: '包名',
            hintText:
                'com.example.${_nameController.text.trim().isEmpty ? 'myapp' : _nameController.text.trim()}',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.domain),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 20),

        // 窄屏：项目类型选择（宽屏在右侧列表）
        if (showPayloadSelector) ...[
          _sectionLabel(t('create.payloadType'), isDark),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: PayloadRegistry.all
                .where((payload) => !payload.hiddenFromCreate)
                .map((payload) => _buildPayloadChip(payload, isDark))
                .toList(),
          ),
          const SizedBox(height: 6),
          Text(
            _payload.description,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black45,
            ),
          ),
          const SizedBox(height: 20),
        ],

        // Flutter 载荷的模板细分（应用 / 包 / 插件）
        if (_payload.isFlutter) ...[
          _sectionLabel(t('create.templateType'), isDark),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTemplateChip('app', t('create.templateApp'), isDark),
              _buildTemplateChip(
                'package',
                t('create.templatePackage'),
                isDark,
              ),
              _buildTemplateChip('plugin', t('create.templatePlugin'), isDark),
            ],
          ),
          const SizedBox(height: 20),
        ],

        // 载荷专属选项（Python 版本 / Java 构建工具 / C++ 编译器与 Makefile）
        _buildPayloadOptions(isDark),

        // 远程仓库选项
        _buildRepoOptions(isDark),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _agentIsolated,
          onChanged: (value) => setState(() => _agentIsolated = value),
          title: const Text('Agent 版本隔离', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '开启后该项目使用独立的 MCP / Skills 配置（不会与其它项目共享）',
            style: TextStyle(fontSize: 11),
          ),
        ),
        const SizedBox(height: 24),

        // 创建按钮
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isCreating ? null : _createProject,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
            child: _isCreating
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(t('create.creating')),
                    ],
                  )
                : Text(t('create.submit')),
          ),
        ),

        const SizedBox(height: 24),

        // 输出日志
        if (_outputLines.isNotEmpty) ...[
          _sectionLabel(t('create.outputLogs'), isDark),
          const SizedBox(height: 8),
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF3C3C3C)
                    : const Color(0xFFDDDDDD),
              ),
            ),
            child: ListView.builder(
              reverse: true,
              itemCount: _outputLines.length,
              itemBuilder: (context, index) {
                final line = _outputLines[_outputLines.length - 1 - index];
                final isError = line.contains('[ERROR]');
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
      ],
    );
  }

  Widget _sectionLabel(String text, bool isDark) => Text(
    text,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: isDark ? Colors.white70 : Colors.black54,
    ),
  );

  /// 右侧项目类型列表（桌面 / 宽屏）
  Widget _buildTypeList(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF1F1F23) : const Color(0xFFFAFAFA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _sectionLabel(t('create.payloadType'), isDark),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final payload in PayloadRegistry.all)
                  if (!payload.hiddenFromCreate)
                    _buildTypeTile(payload, isDark),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _payload.description,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTile(ProjectPayload payload, bool isDark) {
    final selected = _payloadId == payload.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? Colors.blueAccent.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isCreating ? null : () => _selectPayload(payload),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  payload.icon,
                  size: 18,
                  color: selected
                      ? Colors.blueAccent
                      : (isDark ? Colors.white54 : Colors.black45),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    payload.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? (isDark ? Colors.white : Colors.black87)
                          : (isDark ? Colors.white70 : Colors.black54),
                    ),
                  ),
                ),
                if (selected)
                  const Icon(Icons.check, size: 16, color: Colors.blueAccent),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 载荷专属选项
  Widget _buildPayloadOptions(bool isDark) {
    if (_payloadId == 'python') {
      final toolchain = context.watch<ToolchainProvider>();
      final installed = toolchain
          .installedOf(ToolchainKind.python)
          .map((e) => e.version);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('Python 版本', isDark),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _pythonVersion,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.terminal),
              helperText: '托管版本可在「设置 → 工具链」中安装；不选则使用系统 python3',
              helperMaxLines: 2,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('系统 python3')),
              for (final version in installed)
                DropdownMenuItem(
                  value: version,
                  child: Text('Python $version'),
                ),
            ],
            onChanged: _isCreating
                ? null
                : (value) => setState(() => _pythonVersion = value ?? ''),
          ),
          const SizedBox(height: 20),
        ],
      );
    }

    if (_payloadId == 'java') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('构建工具', isDark),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'gradle', label: Text('Gradle')),
              ButtonSegment(value: 'maven', label: Text('Maven')),
            ],
            selected: {_javaBuildTool},
            onSelectionChanged: _isCreating
                ? null
                : (value) => setState(() => _javaBuildTool = value.first),
          ),
          const SizedBox(height: 20),
        ],
      );
    }

    if (_payloadId == 'cpp') {
      final compilers = ToolchainEnvironment.availableCppCompilers();
      final options = compilers.isEmpty ? [_cppCompiler] : compilers;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel('编译器', isDark),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: options.contains(_cppCompiler)
                ? _cppCompiler
                : options.first,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.memory),
              helperText: '仅列出本机已安装的编译器',
              helperMaxLines: 2,
            ),
            items: [
              for (final compiler in options)
                DropdownMenuItem(value: compiler, child: Text(compiler)),
            ],
            onChanged: _isCreating
                ? null
                : (value) =>
                      setState(() => _cppCompiler = value ?? options.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _cppUseMakefile,
            onChanged: _isCreating
                ? null
                : (value) => setState(() => _cppUseMakefile = value),
            title: const Text('启用 Makefile', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '开启生成 Makefile；关闭则生成 CMakeLists.txt',
              style: TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildRepoOptions(bool isDark) {
    // 登录态变化时（如登录成功后返回此页）联动可选平台
    final githubSignedIn = context.watch<GitHubProvider>().isSignedIn;
    final giteeSignedIn = context.watch<GiteeProvider>().isSignedIn;
    final availableHosts = <GitHost>[
      if (githubSignedIn) GitHost.github,
      if (giteeSignedIn) GitHost.gitee,
    ];
    if (_createRepo && availableHosts.isNotEmpty && !_hostSignedIn(_host)) {
      _host = availableHosts.first;
    }

    return Material(
      color: isDark ? const Color(0xFF2D2D30) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('create.repoSwitchTitle')),
              subtitle: Text(
                availableHosts.isEmpty
                    ? '需要先在首页登录 GitHub 或 Gitee 账号'
                    : t('create.repoSwitchSubtitle'),
              ),
              value: _createRepo,
              onChanged: _isCreating
                  ? null
                  : (value) {
                      // 未登录任何平台时不允许开启，并弹窗引导配置账号
                      if (value && availableHosts.isEmpty) {
                        _showNeedAccountDialog();
                        return;
                      }
                      setState(() => _createRepo = value);
                    },
            ),
            if (_createRepo) ...[
              const Divider(height: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Text(
                      t('create.platform'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 12),
                    // 仅展示已登录的平台
                    ...availableHosts.map(
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
                  labelText: t('create.repoNameLabel'),
                  hintText: t('create.repoNameHint'),
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
                  if (name.isEmpty) return t('create.repoNameRequired');
                  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
                    return t('create.repoNameInvalid');
                  }
                  return null;
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 13,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _host == GitHost.gitee
                            ? t('create.repoHintGitee')
                            : t('create.repoHintGithub'),
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.4,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPayloadChip(ProjectPayload payload, bool isDark) {
    final isSelected = _payloadId == payload.id;
    return ChoiceChip(
      avatar: Icon(
        payload.icon,
        size: 16,
        color: isSelected
            ? Colors.white
            : (isDark ? Colors.white70 : Colors.black87),
      ),
      label: Text(payload.name),
      selected: isSelected,
      onSelected: _isCreating ? null : (_) => _selectPayload(payload),
      selectedColor: Colors.blueAccent,
      backgroundColor: isDark
          ? const Color(0xFF2D2D30)
          : const Color(0xFFF0F0F0),
      labelStyle: TextStyle(
        color: isSelected
            ? Colors.white
            : (isDark ? Colors.white70 : Colors.black87),
      ),
    );
  }

  Widget _buildTemplateChip(String value, String label, bool isDark) {
    final isSelected = _template == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: _isCreating
          ? null
          : (_) {
              setState(() {
                _template = value;
              });
            },
      selectedColor: Colors.blueAccent,
      backgroundColor: isDark
          ? const Color(0xFF2D2D30)
          : const Color(0xFFF0F0F0),
      labelStyle: TextStyle(
        color: isSelected
            ? Colors.white
            : (isDark ? Colors.white70 : Colors.black87),
      ),
    );
  }
}
