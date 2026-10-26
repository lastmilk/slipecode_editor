import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/container_provider.dart';
import '../services/container_service.dart';
import '../widgets/log_console.dart';

/// proot 容器设置页面
///
/// 负责安装 proot 二进制与 rootfs 根文件系统
class ContainerSetupScreen extends StatefulWidget {
  const ContainerSetupScreen({super.key});

  @override
  State<ContainerSetupScreen> createState() => _ContainerSetupScreenState();
}

class _ContainerSetupScreenState extends State<ContainerSetupScreen> {
  final TextEditingController _prootUrlController = TextEditingController();
  final TextEditingController _rootfsUrlController =
      TextEditingController(text: ContainerService.defaultRootfsUrl);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContainerProvider>().refresh();
    });
  }

  @override
  void dispose() {
    _prootUrlController.dispose();
    _rootfsUrlController.dispose();
    super.dispose();
  }

  Future<String?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    return result?.files.single.path;
  }

  Future<void> _showResult(bool ok, String successText) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? successText : '操作失败，请查看日志'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContainerProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('容器设置 (proot)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新检测',
            onPressed: provider.busy ? null : provider.refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(provider: provider, isDark: isDark),
          const SizedBox(height: 16),

          if (provider.busy) ...[
            LinearProgressIndicator(
              value: provider.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Text(
              provider.status,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // proot 二进制
          _SectionCard(
            isDark: isDark,
            title: '1. proot 二进制',
            description:
                '需要静态编译的 proot 可执行文件（aarch64）。也可以将其命名为 '
                'libproot.so 放入 android/app/src/main/jniLibs/arm64-v8a/ 后重新安装应用，'
                '这样可避开 Android 10+ 对应用私有目录的执行限制。',
            children: [
              TextField(
                controller: _prootUrlController,
                enabled: !provider.busy,
                decoration: const InputDecoration(
                  labelText: 'proot 下载地址',
                  hintText: 'https://.../proot-aarch64',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: provider.busy
                          ? null
                          : () async {
                              final ok = await provider
                                  .installProotFromUrl(_prootUrlController.text);
                              await _showResult(ok, 'proot 安装成功');
                            },
                      icon: const Icon(Icons.download),
                      label: const Text('下载安装'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: provider.busy
                          ? null
                          : () async {
                              final path = await _pickFile();
                              if (path == null) return;
                              final ok =
                                  await provider.installProotFromFile(path);
                              await _showResult(ok, 'proot 导入成功');
                            },
                      icon: const Icon(Icons.file_open),
                      label: const Text('导入本地文件'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // rootfs
          _SectionCard(
            isDark: isDark,
            title: '2. rootfs 根文件系统',
            description:
                '推荐 Alpine minirootfs（约 3MB）。也可以导入本地 tar.gz 镜像。'
                '解压使用系统 tar，Android 9+ 设备均可用。',
            children: [
              TextField(
                controller: _rootfsUrlController,
                enabled: !provider.busy,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'rootfs 下载地址',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: provider.busy
                          ? null
                          : () async {
                              final ok = await provider
                                  .installRootfsFromUrl(_rootfsUrlController.text);
                              await _showResult(ok, 'rootfs 安装成功');
                            },
                      icon: const Icon(Icons.download),
                      label: const Text('下载安装'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: provider.busy
                          ? null
                          : () async {
                              final path = await _pickFile();
                              if (path == null) return;
                              final ok =
                                  await provider.installRootfsFromFile(path);
                              await _showResult(ok, 'rootfs 导入成功');
                            },
                      icon: const Icon(Icons.file_open),
                      label: const Text('导入 tar.gz'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Text(
                '执行日志',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: provider.clearLogs,
                child: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 220,
            child: LogConsole(
              lines: provider.logs,
              emptyText: '安装过程日志将显示在这里',
            ),
          ),
          const SizedBox(height: 16),

          // 说明
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF262626) : const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFFFE082),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.amber[700]),
                    const SizedBox(width: 6),
                    const Text(
                      '构建工具链说明',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '容器安装完成后，可在「构建」页面依次初始化：\n'
                  '• 基础依赖（bash/git/curl/openjdk17）\n'
                  '• Flutter SDK（/opt/flutter）\n'
                  '• Android SDK（/opt/android-sdk）\n'
                  '随后即可在终端或构建页运行 flutter build。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final ContainerProvider provider;
  final bool isDark;

  const _StatusCard({required this.provider, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final ready = provider.ready;
    final color = ready ? Colors.green : Colors.orange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252526) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ready ? Icons.check_circle : Icons.warning_amber_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                provider.checking
                    ? '正在检测环境...'
                    : (ready ? '容器已就绪' : '容器未就绪'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              if (provider.arch.isNotEmpty)
                Chip(
                  label: Text(
                    provider.arch,
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: 'proot',
            value: provider.prootPath ?? '未找到',
            ok: provider.prootPath != null,
          ),
          const SizedBox(height: 6),
          _InfoRow(
            label: 'rootfs',
            value: provider.rootfsInstalled ? provider.rootfsPath : '未安装',
            ok: provider.rootfsInstalled,
          ),
          const SizedBox(height: 6),
          _InfoRow(label: '环境目录', value: provider.envRootPath),
          if (provider.error != null) ...[
            const SizedBox(height: 10),
            Text(
              provider.error!,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool? ok;

  const _InfoRow({required this.label, required this.value, this.ok});

  @override
  Widget build(BuildContext context) {
    final color = ok == null
        ? Colors.grey
        : (ok! ? Colors.green : Colors.orange);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String description;
  final List<Widget> children;
  final bool isDark;

  const _SectionCard({
    required this.title,
    required this.description,
    required this.children,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252526) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E0E0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
