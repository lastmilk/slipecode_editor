import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
import '../l10n/app_localizations.dart';
import '../payloads/project_payload.dart';
import '../services/git_host.dart';
import '../services/project_create_service.dart';

/// 创建新项目页面
class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({super.key});

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
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

  final List<String> _outputLines = [];

  @override
  void initState() {
    super.initState();
    // 项目默认保存在应用私有目录（无需任何存储权限）。
    // 新版本已移除「共享存储」功能：如需使用已有项目，
    // 请从首页通过系统文件选择器导入。
    final settings = context.read<SettingsProvider>().settings;
    getApplicationDocumentsDirectory().then((dir) {
      if (!mounted || _pathController.text.isNotEmpty) return;
      setState(() => _pathController.text = p.join(dir.path, 'Projects'));
    });

    // 偏好设置中的默认 Git 平台与建仓开关
    _host = settings.defaultGitHost;
    _createRepo = settings.createRepoOnCreate;

    // 仓库名默认等于项目名
    _nameController.addListener(() {
      if (!_repoNameEdited) {
        _repoNameController.text = _nameController.text.trim();
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    _orgController.dispose();
    _repoNameController.dispose();
    super.dispose();
  }

  String get _targetPath {
    final dir = _pathController.text.trim();
    final name = _nameController.text.trim();
    return p.join(dir, name);
  }

  Future<void> _createProject() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isCreating = true;
      _outputLines.clear();
    });

    final createService = ProjectCreateService();
    final projectProvider = context.read<ProjectProvider>();

    try {
      await for (final line in createService.createProject(
        payload: _payload,
        projectName: _nameController.text.trim(),
        targetPath: _targetPath,
        org: _orgController.text.trim(),
        template: _template,
      )) {
        setState(() {
          _outputLines.add(line);
        });
      }

      // 打开刚创建的项目
      await projectProvider.openProject(_targetPath);
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
                _targetPath,
                repoName,
                onLog: (line) {
                  if (mounted) setState(() => _outputLines.add(line));
                },
              );
            } else {
              if (mounted) {
                setState(() => _outputLines.add(
                      t('create.warnNotSignedInGithub'),
                    ));
              }
            }
          } else {
            final gitee = context.read<GiteeProvider>();
            if (gitee.isSignedIn) {
              await gitee.createRepoWithInitialPush(
                _targetPath,
                repoName,
                onLog: (line) {
                  if (mounted) setState(() => _outputLines.add(line));
                },
              );
            } else {
              if (mounted) {
                setState(() => _outputLines.add(
                      t('create.warnNotSignedInGitee'),
                    ));
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
        if (mounted) {
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

    return Scaffold(
      appBar: AppBar(
        title: Text(t('create.title')),
        elevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
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

            // 项目路径
            TextFormField(
              controller: _pathController,
              enabled: !_isCreating,
              decoration: InputDecoration(
                labelText: t('create.location'),
                hintText: '/storage/emulated/0/Projects',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.folder),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: _isCreating
                      ? null
                      : () async {
                          // 简单提示
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(t('create.manualPathHint')),
                            ),
                          );
                        },
                ),
              ),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return t('create.locationRequired');
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Org
            TextFormField(
              controller: _orgController,
              enabled: !_isCreating,
              decoration: InputDecoration(
                labelText: t('create.orgLabel'),
                hintText: 'com.example',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.domain),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),

            // 项目载荷（决定模板代码 / 语法高亮 / GitHub Actions）
            Text(
              t('create.payloadType'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: PayloadRegistry.all
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

            // Flutter 载荷的模板细分（应用 / 包 / 插件）
            if (_payload.isFlutter) ...[
              Text(
                t('create.templateType'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
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

            // 远程仓库选项
            _buildRepoOptions(isDark),
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
              Text(
                t('create.outputLogs'),
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
        ),
      ),
    );
  }

  Widget _buildRepoOptions(bool isDark) {
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
            title: Text(t('create.repoSwitchTitle')),
            subtitle: Text(t('create.repoSwitchSubtitle')),
            value: _createRepo,
            onChanged: _isCreating
                ? null
                : (value) => setState(() => _createRepo = value),
          ),
          if (_createRepo) ...[
            const Divider(height: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Text(t('create.platform'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 12),
                  ...GitHost.values.map(
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
    );
  }

  Widget _buildPayloadChip(ProjectPayload payload, bool isDark) {
    final isSelected = _payloadId == payload.id;
    return ChoiceChip(
      avatar: Icon(
        payload.icon,
        size: 16,
        color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
      ),
      label: Text(payload.name),
      selected: isSelected,
      onSelected: _isCreating ? null : (_) => setState(() => _payloadId = payload.id),
      selectedColor: Colors.blueAccent,
      backgroundColor: isDark ? const Color(0xFF2D2D30) : const Color(0xFFF0F0F0),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
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
      backgroundColor: isDark ? const Color(0xFF2D2D30) : const Color(0xFFF0F0F0),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
      ),
    );
  }
}
