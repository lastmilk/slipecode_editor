import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../payloads/loader/loader_payload.dart';
import '../providers/ai_provider.dart';
import '../providers/project_provider.dart';
import '../services/loader_project_service.dart';
import 'build_screen.dart';

/// Loader 项目构建页
///
/// Loader 项目的构建分两大环节：
/// 1. **AI 介入**：设计稿已包含完整 Vibe，把 Vibe 提示词发给 Agent，
///    让 AI 无感地完成整个项目的代码生成；
/// 2. **实际构建**：代码生成完成后，走 Root Payload 定义的云端构建环境出包。
class LoaderBuildScreen extends StatefulWidget {
  const LoaderBuildScreen({super.key});

  @override
  State<LoaderBuildScreen> createState() => _LoaderBuildScreenState();
}

class _LoaderBuildScreenState extends State<LoaderBuildScreen> {
  Map<String, dynamic>? _manifest;
  bool _loading = true;

  /// AI 介入是否已发起（防止重复点击）
  bool _aiDispatched = false;

  @override
  void initState() {
    super.initState();
    _loadManifest();
  }

  Future<void> _loadManifest() async {
    final projectPath = context.read<ProjectProvider>().projectPath;
    final manifest = projectPath == null
        ? null
        : await LoaderProjectService.readManifest(projectPath);
    if (!mounted) return;
    setState(() {
      _manifest = manifest;
      _loading = false;
    });
  }

  /// 环节一：把完整 Vibe 提示词交给 Agent，AI 无感生成全部代码
  Future<void> _startAiIntervention() async {
    final projectPath = context.read<ProjectProvider>().projectPath;
    if (projectPath == null || _aiDispatched) return;
    try {
      final prompt = await LoaderProjectService.composeVibePrompt(projectPath);
      if (!mounted) return;
      setState(() => _aiDispatched = true);
      // 不等待 Agent 跑完：任务在 Agent 面板中流式进行
      unawaited(context.read<AiProvider>().sendMessage(prompt));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已发起 AI 介入：回到编辑器 → Agent 面板可查看生成进度'),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI 介入发起失败：$e'), backgroundColor: Colors.red),
      );
    }
  }

  /// 环节二：进入传统的实际构建（云端出包，需先登录 Git 平台）
  Future<void> _startRealBuild() async {
    final ok = await BuildScreen.ensureSignedIn(context);
    if (!ok || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BuildScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Loader 构建')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _manifest == null
              ? _buildNotLoader(isDark)
              : _buildBody(isDark),
    );
  }

  Widget _buildNotLoader(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.report_gmailerrorred_outlined,
                size: 48, color: Colors.orange[300]),
            const SizedBox(height: 12),
            Text(
              '当前项目不是 Loader 项目\n（缺少 ${LoaderProjectService.manifestName}）',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    final manifest = _manifest!;
    final root = (manifest['root'] as Map).cast<String, dynamic>();
    final rootSpec = RootPayloadRegistry.byId(root['id'] as String?);
    final rootParams =
        ((root['params'] as Map?) ?? const {}).cast<String, dynamic>();
    final systems = ((manifest['systems'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final blockCount = systems.fold<int>(
        0, (sum, s) => sum + ((s['blocks'] as List?) ?? const []).length);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---- 组装摘要 ----
        _sectionTitle('组装摘要', isDark),
        const SizedBox(height: 8),
        _buildSummaryCard(
          manifest,
          rootSpec,
          rootParams,
          systems,
          blockCount,
          isDark,
        ),
        const SizedBox(height: 20),

        // ---- 环节一：AI 介入 ----
        _sectionTitle('环节一 · AI 介入', isDark),
        const SizedBox(height: 8),
        _buildAiCard(isDark),
        const SizedBox(height: 20),

        // ---- 环节二：实际构建 ----
        _sectionTitle('环节二 · 实际构建', isDark),
        const SizedBox(height: 8),
        _buildRealBuildCard(rootSpec, rootParams, isDark),
      ],
    );
  }

  Widget _sectionTitle(String text, bool isDark) => Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      );

  Widget _buildSummaryCard(
    Map<String, dynamic> manifest,
    RootPayloadSpec rootSpec,
    Map<String, dynamic> rootParams,
    List<Map<String, dynamic>> systems,
    int blockCount,
    bool isDark,
  ) {
    final draftName = manifest['draftName'] as String?;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(rootSpec.icon, size: 16, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${rootSpec.name} · ${rootSpec.buildEnvLabel}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '仓库：${rootParams['git_host'] ?? 'github'}'
            '${draftName != null ? ' · 设计稿：$draftName' : ''}\n'
            'System Payload ${systems.length} 个 · Block Payload $blockCount 个',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          if (systems.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in systems)
                  _systemChip(s, isDark),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _systemChip(Map<String, dynamic> s, bool isDark) {
    final spec = SystemPayloadRegistry.byId(s['id'] as String?);
    final blocks = ((s['blocks'] as List?) ?? const []).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.teal.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.icon, size: 13, color: Colors.teal),
          const SizedBox(width: 4),
          Text(
            '${s['folder']}${blocks > 0 ? '（$blocks）' : ''}',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiCard(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1F3A5F), const Color(0xFF2D2D30)]
              : [const Color(0xFFE3F2FD), Colors.white],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome,
                  size: 18, color: Colors.blueAccent),
              const SizedBox(width: 6),
              Text(
                _aiDispatched ? 'AI 介入已发起' : '让 AI 无感完成整个项目',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '设计稿已包含完整 Vibe。点击后会把 PAYLOAD.md、各端 SYSTEM.md 与 '
            'blocks/*.md 组装成一次总指令发给 Agent，Agent 将按它生成全部端的代码。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _aiDispatched ? null : _startAiIntervention,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    isDark ? const Color(0xFF3C3C3C) : Colors.grey[300],
              ),
              icon: Icon(_aiDispatched ? Icons.check : Icons.auto_awesome,
                  size: 18),
              label: Text(_aiDispatched ? '已发起（去 Agent 面板查看）' : '开始 AI 介入'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRealBuildCard(
      RootPayloadSpec rootSpec, Map<String, dynamic> rootParams, bool isDark) {
    final gitHost = rootParams['git_host'] ?? 'github';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D30) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFE0E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud_done_outlined, size: 18, color: Colors.teal),
              SizedBox(width: 6),
              Text(
                '云端出包',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'AI 生成代码完成并推送到 $gitHost 仓库后，'
            '由 Root Payload「${rootSpec.name}」定义的 '
            '${rootSpec.buildEnvLabel} 云端环境完成实际构建。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _startRealBuild,
              icon: const Icon(Icons.build, size: 18),
              label: const Text('前往实际构建'),
            ),
          ),
        ],
      ),
    );
  }
}
