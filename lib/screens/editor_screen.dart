import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../providers/git_sync_provider.dart';
import '../providers/project_provider.dart';
import '../widgets/code_editor.dart';
import '../widgets/editor_tabs.dart';
import '../widgets/file_tree.dart';
import 'build_screen.dart';
import 'terminal_screen.dart';

/// 主编辑器界面
///
/// 左侧文件树 + 右侧标签页 + 编辑区 + 底部状态栏
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  bool _showFileTree = true;

  @override
  void initState() {
    super.initState();
    // 如果已有项目路径但还没加载文件树
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final projectProvider = context.read<ProjectProvider>();
      if (projectProvider.projectPath != null &&
          projectProvider.fileTree == null) {
        projectProvider.refreshFileTree();
      }
    });
  }

  Future<void> _handleFileTap(String path) async {
    final editorProvider = context.read<EditorProvider>();
    await editorProvider.openFile(path);
  }

  Future<void> _handleSave() async {
    final editorProvider = context.read<EditorProvider>();
    if (editorProvider.hasActiveFile) {
      final savedPath = editorProvider.activeFile!.path;
      final ok = await editorProvider.saveActiveFile();
      if (!mounted) return;
      if (ok) {
        // 标记变更，防抖后自动 push 到 GitHub（AI 自动同步）
        context.read<GitSyncProvider>().markChanged(savedPath);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '✓ 已保存' : '保存失败'),
          backgroundColor: ok ? Colors.green : Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  String _detectLanguage(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.dart')) return 'dart';
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return 'yaml';
    if (lower.endsWith('.json')) return 'json';
    if (lower.endsWith('.xml')) return 'xml';
    if (lower.endsWith('.gradle') || lower.endsWith('.kts')) return 'kotlin';
    if (lower.endsWith('.html')) return 'xml';
    if (lower.endsWith('.md')) return 'markdown';
    if (lower.endsWith('.kt')) return 'kotlin';
    if (lower.endsWith('.java')) return 'java';
    return 'plaintext';
  }

  @override
  Widget build(BuildContext context) {
    final projectProvider = context.watch<ProjectProvider>();
    final editorProvider = context.watch<EditorProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          projectProvider.projectPath?.split(RegExp(r'[/\\]')).last ?? '编辑器',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: '终端 (proot)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TerminalScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.build),
            tooltip: '构建',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BuildScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新文件树',
            onPressed: projectProvider.refreshFileTree,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存 (Ctrl+S)',
            onPressed: _handleSave,
          ),
          IconButton(
            icon: Icon(_showFileTree ? Icons.menu_open : Icons.menu),
            tooltip: '切换侧边栏',
            onPressed: () => setState(() => _showFileTree = !_showFileTree),
          ),
        ],
      ),
      body: Row(
        children: [
          // 左侧文件树
          if (_showFileTree)
            Container(
              width: 240,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: isDark
                        ? const Color(0xFF3C3C3C)
                        : const Color(0xFFE0E0E0),
                  ),
                ),
                color: isDark ? const Color(0xFF252526) : const Color(0xFFF3F3F3),
              ),
              child: Column(
                children: [
                  // 侧边栏标题
                  Container(
                    padding: const EdgeInsets.all(12),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '资源管理器',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black45,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // 文件树
                  Expanded(
                    child: FileTree(
                      root: projectProvider.fileTree,
                      isLoading: projectProvider.isLoading,
                      onFileTap: _handleFileTap,
                    ),
                  ),
                ],
              ),
            ),

          // 右侧主编辑区
          Expanded(
            child: Column(
              children: [
                // 标签页栏
                const EditorTabs(),

                // 编辑区 / 欢迎提示
                Expanded(
                  child: editorProvider.hasActiveFile
                      ? _buildEditor(editorProvider, isDark)
                      : _buildWelcome(isDark),
                ),

                // 底部状态栏
                _buildStatusBar(editorProvider, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(EditorProvider editorProvider, bool isDark) {
    final activeFile = editorProvider.activeFile!;
    final language = _detectLanguage(activeFile.path);

    return Column(
      children: [
        // 文件名 / 语言提示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          alignment: Alignment.centerRight,
          child: Text(
            '$language • ${activeFile.path}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ),
        Expanded(
          child: CodeEditor(
            initialContent: activeFile.content,
            language: language,
            onChanged: (content) {
              editorProvider.updateActiveContent(content);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWelcome(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.code,
            size: 64,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          const SizedBox(height: 16),
          Text(
            '从左侧文件树选择文件开始编辑',
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(EditorProvider editorProvider, bool isDark) {
    final activeFile = editorProvider.activeFile;
    final bgColor = isDark ? const Color(0xFF007ACC) : const Color(0xFF007ACC);

    return Container(
      height: 24,
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (activeFile != null) ...[
            Text(
              activeFile.isModified ? '● 已修改' : '● 已保存',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 20),
            Text(
              _detectLanguage(activeFile.path),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 20),
            Text(
              '${activeFile.content.split('\n').length} 行',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
              ),
            ),
          ] else
            const Text(
              '就绪',
              style: TextStyle(fontSize: 11, color: Colors.white),
            ),
        ],
      ),
    );
  }
}
