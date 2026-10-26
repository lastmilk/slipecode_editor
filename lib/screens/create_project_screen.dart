import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../providers/github_provider.dart';
import '../providers/project_provider.dart';
import '../services/flutter_service.dart';

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

  String _template = 'app';
  bool _isCreating = false;
  final List<String> _outputLines = [];

  @override
  void initState() {
    super.initState();
    // 设置默认路径（Android 上常用的 Projects 目录）
    _pathController.text = '/storage/emulated/0/Projects';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    _orgController.dispose();
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

    final flutterService = FlutterService();
    final projectProvider = context.read<ProjectProvider>();

    try {
      await for (final line in flutterService.createProject(
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

      // 已连接 GitHub 时：自动创建仓库并推送初始代码
      final github = context.read<GitHubProvider>();
      if (github.isSignedIn) {
        try {
          await github.createRepoWithInitialPush(
            _targetPath,
            _nameController.text.trim(),
            onLog: (line) {
              if (mounted) setState(() => _outputLines.add(line));
            },
          );
        } catch (e) {
          if (mounted) {
            setState(() => _outputLines.add('[ERROR] GitHub 仓库创建失败: $e'));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('项目已创建，但 GitHub 仓库创建失败: $e'),
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
              decoration: const InputDecoration(
                labelText: '项目名称',
                hintText: 'my_flutter_app',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge),
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

            // 模板选择
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
