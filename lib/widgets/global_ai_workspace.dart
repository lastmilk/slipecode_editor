import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../providers/ai_provider.dart';
import '../providers/project_provider.dart';
import '../screens/agc_screen.dart';
import 'ai_connector_panel.dart';

class GlobalAiWorkspace extends StatefulWidget {
  const GlobalAiWorkspace({super.key, required this.projects});

  final List<Project> projects;

  @override
  State<GlobalAiWorkspace> createState() => _GlobalAiWorkspaceState();
}

class _GlobalAiWorkspaceState extends State<GlobalAiWorkspace> {
  bool _switching = false;

  String get _globalValue => 'global';

  String _projectValue(Project project) => 'project:${project.path}';

  String _contextLabel(ProjectProvider provider) {
    final path = provider.projectPath;
    if (path == null || path.isEmpty) return '全局';
    for (final project in widget.projects) {
      if (project.path == path) return project.name;
    }
    return p.basename(path);
  }

  Future<void> _selectContext(String selection) async {
    final ai = context.read<AiProvider>();
    final provider = context.read<ProjectProvider>();
    if (ai.isThinking || _switching) {
      _showMessage('Agent 执行期间不能切换上下文，请等待完成或先取消任务');
      return;
    }
    final previousPath = provider.projectPath;
    if (selection == _globalValue && previousPath == null) return;
    if (selection == 'project:$previousPath') return;

    Project? target;
    if (selection != _globalValue) {
      final path = selection.substring('project:'.length);
      for (final project in widget.projects) {
        if (project.path == path) {
          target = project;
          break;
        }
      }
      if (target == null || target.missing || !Directory(path).existsSync()) {
        _showMessage('项目目录不存在，无法挂载');
        return;
      }
    }

    setState(() => _switching = true);
    try {
      if (target == null) {
        await provider.closeProject();
      } else {
        await provider.openProject(target.path, kind: target.kind);
        if (provider.error != null) throw StateError(provider.error!);
      }
    } catch (error) {
      // 打开失败时恢复原上下文，避免全局会话错误地停留在损坏项目上。
      try {
        if (previousPath == null) {
          await provider.closeProject();
        } else {
          await provider.openProject(previousPath);
        }
      } catch (_) {
        // 原项目的恢复错误由 ProjectProvider 状态继续呈现。
      }
      if (mounted) _showMessage('挂载项目失败：$error');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showHistory() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: 640,
          child: AgcHistoryPanel(
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    );
  }

  Future<void> _showExtensions() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 720,
          height: 700,
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 8, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Agent 扩展',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'MCP / Skills'),
                    Tab(text: 'Connectors'),
                  ],
                ),
                const Expanded(
                  child: TabBarView(
                    children: [AgcToolsPanel(), AiConnectorPanel()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<AiProvider>();
    final project = context.watch<ProjectProvider>();
    final busy = ai.isThinking || _switching;
    final hasProject = (project.projectPath ?? '').isNotEmpty;
    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 62),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface
                .withValues(alpha: 0.58),
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, size: 20),
              const SizedBox(width: 8),
              const Text(
                '全局 AI',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Flexible(
                fit: FlexFit.loose,
                child: PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: busy ? 'Agent 执行期间无法切换上下文' : '选择对话上下文',
                  onSelected: _selectContext,
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: _globalValue,
                      child: Row(
                        children: [
                          Icon(
                            hasProject
                                ? Icons.public_outlined
                                : Icons.check_circle_outline,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          const Text('全局（不挂载项目）'),
                        ],
                      ),
                    ),
                    if (widget.projects.isNotEmpty) const PopupMenuDivider(),
                    for (final item in widget.projects)
                      PopupMenuItem<String>(
                        value: _projectValue(item),
                        enabled: !item.missing,
                        child: Row(
                          children: [
                            Icon(
                              item.path == project.projectPath
                                  ? Icons.check_circle_outline
                                  : Icons.folder_outlined,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: Chip(
                    avatar: Icon(
                      hasProject ? Icons.folder_outlined : Icons.public,
                      size: 16,
                    ),
                    label: Text(
                      _switching ? '正在切换…' : _contextLabel(project),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: busy ? 'Agent 执行期间无法新建会话' : '新建会话',
                onPressed: busy ? null : ai.startNewSession,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: '会话历史',
                onPressed: _showHistory,
                icon: const Icon(Icons.history),
              ),
              TextButton.icon(
                onPressed: _showExtensions,
                icon: const Icon(Icons.extension_outlined, size: 18),
                label: const Text('MCP · Skills · Connectors'),
              ),
            ],
          ),
        ),
        const Expanded(child: AgcScreen(global: true)),
      ],
    );
  }
}
