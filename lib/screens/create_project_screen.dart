import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../providers/settings_provider.dart';
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
    // 设置默认路径（Android 外部存储 / iOS 应用文档目录）
    if (Platform.isAndroid) {
      _pathController.text = '/storage/emulated/0/Projects';
    } else {
      getApplicationDocumentsDirectory().then((dir) {
        if (!mounted || _pathController.text.isNotEmpty) return;
        setState(() => _pathController.text = p.join(dir.path, 'Projects'));
      });
    }

    // 偏好设置中的默认 Git 平台与建仓开关
    final settings = context.read<SettingsProvider>().settings;
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
                      '[WARN] 未登录 GitHub，已跳过创建仓库',
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
                      '[WARN] 未登录 Gitee（或未配置后端），已跳过创建仓库',
                    ));
              }
            }
          }
        } catch (e) {
          if (mounted) {
            setState(
              () => _outputLines.add('[ERROR] ${_host.label} 仓库创建失败: $e'),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('项目已创建，但 ${_host.label} 仓库创建失败: $e'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }

      if (mounted) {
        // 先显示完成，再跳转到编辑器
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ 项目创建成功！'),
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
            content: Text('创建失败: $e'),
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
        title: const Text('创建新项目'),
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
                labelText: '项目名称',
                hintText: _payload.projectNameHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.badge),
              ),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入项目名称';
                if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value)) {
                  return '项目名称只能包含小写字母、数字和下划线';
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
                labelText: '存放目录',
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
                            const SnackBar(
                              content: Text(
                                '请手动输入目标目录路径',
                              ),
                            ),
                          );
                        },
                ),
              ),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入存放目录';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Org
            TextFormField(
              controller: _orgController,
              enabled: !_isCreating,
              decoration: const InputDecoration(
                labelText: '组织 (Android 包名前缀)',
                hintText: 'com.example',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.domain),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),

            // 项目载荷（决定模板代码 / 语法高亮 / GitHub Actions）
            Text(
              '项目类型（Payload）',
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
                '模板类型',
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
                  _buildTemplateChip('app', '应用', isDark),
                  _buildTemplateChip('package', '包', isDark),
                  _buildTemplateChip('plugin', '插件', isDark),
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
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text('正在创建...'),
                        ],
                      )
                    : const Text('创建项目'),
              ),
            ),

            const SizedBox(height: 24),

            // 输出日志
            if (_outputLines.isNotEmpty) ...[
              Text(
                '执行日志',
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
            title: const Text('创建远程仓库并推送'),
            subtitle: const Text('创建后把模板文件推送到所选平台'),
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
                  const Text('平台', style: TextStyle(fontSize: 13)),
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
                labelText: '仓库名称',
                hintText: '默认与项目名称相同',
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
                if (name.isEmpty) return '请输入仓库名称';
                if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
                  return '仓库名只能包含字母、数字、点、下划线和中划线';
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
                          ? '同名仓库已存在时会自动改为 _1、_2；Gitee Go 无 macOS Runner，iOS 构建不可用'
                          : '同名仓库已存在时会自动改为 _1、_2；iOS 构建使用 macOS Runner',
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
