import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
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
        content: Text(ok ? successText : t('containerSetup.opFailed')),
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
        title: Text(t('containerSetup.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('containerSetup.recheck'),
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
            title: t('containerSetup.prootSection'),
            description: t('containerSetup.prootSectionDesc'),
            children: [
              TextField(
                controller: _prootUrlController,
                enabled: !provider.busy,
                decoration: InputDecoration(
                  labelText: t('containerSetup.prootUrlLabel'),
                  hintText: 'https://.../proot-aarch64',
                  border: const OutlineInputBorder(),
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
                              await _showResult(
                                  ok, t('containerSetup.prootInstalled'));
                            },
                      icon: const Icon(Icons.download),
                      label: Text(t('containerSetup.downloadInstall')),
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
                              await _showResult(
                                  ok, t('containerSetup.prootImported'));
                            },
                      icon: const Icon(Icons.file_open),
                      label: Text(t('containerSetup.importLocal')),
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
            title: t('containerSetup.rootfsSection'),
            description: t('containerSetup.rootfsSectionDesc'),
            children: [
              TextField(
                controller: _rootfsUrlController,
                enabled: !provider.busy,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: t('containerSetup.rootfsUrlLabel'),
                  border: const OutlineInputBorder(),
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
                              await _showResult(
                                  ok, t('containerSetup.rootfsInstalled'));
                            },
                      icon: const Icon(Icons.download),
                      label: Text(t('containerSetup.downloadInstall')),
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
                              await _showResult(
                                  ok, t('containerSetup.rootfsImported'));
                            },
                      icon: const Icon(Icons.file_open),
                      label: Text(t('containerSetup.importTarGz')),
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
                t('containerSetup.logs'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: provider.clearLogs,
                child: Text(t('containerSetup.clear')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 220,
            child: LogConsole(
              lines: provider.logs,
              emptyText: t('containerSetup.logsEmpty'),
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
                    Text(
                      t('containerSetup.toolchainTitle'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  t('containerSetup.toolchainDesc'),
                  style: const TextStyle(fontSize: 12, height: 1.5),
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
                    ? t('containerSetup.checking')
                    : (ready
                        ? t('containerSetup.ready')
                        : t('containerSetup.notReady')),
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
            value: provider.prootPath ?? t('containerSetup.notFound'),
            ok: provider.prootPath != null,
          ),
          const SizedBox(height: 6),
          _InfoRow(
            label: 'rootfs',
            value: provider.rootfsInstalled
                ? provider.rootfsPath
                : t('containerSetup.notInstalled'),
            ok: provider.rootfsInstalled,
          ),
          const SizedBox(height: 6),
          _InfoRow(
              label: t('containerSetup.envDir'), value: provider.envRootPath),
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
