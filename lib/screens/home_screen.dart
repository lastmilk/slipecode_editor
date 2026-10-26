import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/project_provider.dart';
import 'create_project_screen.dart';
import 'editor_screen.dart';

/// 应用主页
///
/// 显示欢迎界面和主要操作入口
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    // 先请求基本存储权限
    if (await Permission.storage.status != PermissionStatus.granted) {
      await Permission.storage.request();
    }

    // Android 11+ 请求"所有文件访问权限"
    if (await Permission.manageExternalStorage.status != PermissionStatus.granted) {
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _openExistingProject() async {
    // 使用 file_picker 选择目录（项目根目录）
    final provider = context.read<ProjectProvider>();

    // 在移动平台上用简单的路径输入代替（file_picker 选择目录可能有兼容性问题）
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('打开已有项目'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入项目根目录完整路径\n如: /storage/emulated/0/Projects/my_app',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('打开'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await provider.openProject(result);
      if (mounted && provider.projectPath != null) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const EditorScreen()),
        );
      } else if (mounted && provider.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(provider.error!)),
        );
      }
    }
  }

  Future<void> _createNewProject() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateProjectScreen()),
    );

    // 如果创建成功，自动切换到编辑器
    if (created == true && mounted) {
      final provider = context.read<ProjectProvider>();
      if (provider.projectPath != null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const EditorScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF1E1E1E), const Color(0xFF121212)]
                : [const Color(0xFFF5F7FA), const Color(0xFFE4E8EC)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo/标题
                const Icon(
                  Icons.code,
                  size: 80,
                  color: Colors.blueAccent,
                ),
                const SizedBox(height: 16),
                Text(
                  'SlipCode',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Flutter on Flutter — 在 Flutter 中编辑 Flutter',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 48),

                // 操作按钮
                _ActionButton(
                  icon: Icons.add,
                  label: '创建新项目',
                  subtitle: '使用 flutter create 生成项目骨架',
                  onTap: _createNewProject,
                  isDark: isDark,
                  primary: true,
                ),
                const SizedBox(height: 16),
                _ActionButton(
                  icon: Icons.folder_open,
                  label: '打开已有项目',
                  subtitle: '浏览本地文件并加载项目',
                  onTap: _openExistingProject,
                  isDark: isDark,
                ),

                const Spacer(),

                // 底部版本信息
                Text(
                  'v1.0.0 • Flutter 3.47.8',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white30 : Colors.black38,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDark;
  final bool primary;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    required this.isDark,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: primary
            ? Colors.blueAccent
            : (isDark ? const Color(0xFF2D2D30) : Colors.white),
        borderRadius: BorderRadius.circular(12),
        elevation: primary ? 4 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: primary
                        ? Colors.white24
                        : Colors.blueAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    color: primary ? Colors.white : Colors.blueAccent,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: primary
                              ? Colors.white
                              : (isDark ? Colors.white : Colors.black87),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: primary
                              ? Colors.white70
                              : (isDark ? Colors.white54 : Colors.black54),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: primary
                      ? Colors.white70
                      : (isDark ? Colors.white38 : Colors.black26),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
