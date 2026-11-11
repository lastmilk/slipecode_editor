import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/project_provider.dart';
import '../screens/create_loader_project_screen.dart';
import '../screens/create_project_screen.dart';
import '../screens/design_draft_editor_screen.dart';
import '../screens/editor_screen.dart';

/// 新建项目流程（底栏中间的「＋」以及首页入口共用）
///
/// 支持 Loader 项目 / 传统项目 / 设计稿三种类型；
/// 创建成功后直接进入编辑器，并通过 [onDone] 通知调用方刷新列表。
Future<void> showCreateProjectFlow(
  BuildContext context, {
  VoidCallback? onDone,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '创建新项目',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.rocket_launch_outlined,
                color: Colors.blueAccent),
            title: const Text('创建 Loader 项目（推荐）'),
            subtitle: const Text('采用设计稿组装三层 Payload，AI 无感完成项目'),
            onTap: () => Navigator.pop(sheetContext, 'loader'),
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('创建传统项目'),
            subtitle: const Text('Flutter / Android / Node / Web 等内置模板'),
            onTap: () => Navigator.pop(sheetContext, 'classic'),
          ),
          ListTile(
            leading: const Icon(Icons.design_services_outlined,
                color: Colors.teal),
            title: const Text('创建设计稿'),
            subtitle: const Text('先在可视化编辑器中编排 Payload，稍后用它生成项目'),
            onTap: () => Navigator.pop(sheetContext, 'draft'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;

  switch (action) {
    case 'loader':
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const CreateLoaderProjectScreen()),
      );
      if (context.mounted) {
        await _openCreatedProject(context, created, onDone);
      }
    case 'classic':
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const CreateProjectScreen()),
      );
      if (context.mounted) {
        await _openCreatedProject(context, created, onDone);
      }
    case 'draft':
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DesignDraftEditorScreen()),
      );
      onDone?.call();
  }
}

/// 创建成功后打开编辑器并通知刷新
Future<void> _openCreatedProject(
  BuildContext context,
  bool? created,
  VoidCallback? onDone,
) async {
  if (created == true && context.mounted) {
    final provider = context.read<ProjectProvider>();
    if (provider.projectPath != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const EditorScreen()),
      );
    }
  }
  onDone?.call();
}
