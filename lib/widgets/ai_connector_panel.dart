import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/tool_contract.dart';
import '../models/ai_connector.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import '../services/ai_connector_service.dart';

class AiConnectorPanel extends StatefulWidget {
  const AiConnectorPanel({super.key});

  @override
  State<AiConnectorPanel> createState() => _AiConnectorPanelState();
}

class _AiConnectorPanelState extends State<AiConnectorPanel> {
  final Set<String> _busy = {};

  Future<void> _run(
    String id,
    Future<void> Function() action,
    String successMessage,
  ) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
      if (mounted && successMessage.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ConnectorService.safeError(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _disconnect(String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('断开 $name？'),
        content: const Text(
          '这会清除本机保存的授权，并同时影响仓库同步和构建。'
          '如果只是暂时不让 Agent 使用，请关闭连接器开关。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('断开并清除授权'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      id,
      () => context.read<ConnectorService>().disconnect(id),
      '已断开 $name，本机授权已清除',
    );
  }

  Future<void> _cancelAuthorization(String id) async {
    if (id == 'github') {
      await context.read<GitHubProvider>().cancelSignIn();
    } else if (id == 'gitee') {
      await context.read<GiteeProvider>().cancelSignIn();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<ConnectorService, GitHubProvider, GiteeProvider>(
      builder: (context, service, github, gitee, _) {
        if (service.connectors.isEmpty) {
          return const Center(child: Text('尚未注册连接器'));
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              'OAuth 授权由对应平台管理。连接器只向 Agent 暴露下方列出的只读工具；'
              'OAuth granted scopes 可能包含更宽权限，不代表 Agent 可以执行写操作。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final connector in service.connectors)
              _buildConnectorCard(service, connector.definition),
          ],
        );
      },
    );
  }

  Widget _buildConnectorCard(
    ConnectorService service,
    ConnectorDefinition definition,
  ) {
    final snapshot = service.snapshotFor(definition.id);
    final busy = _busy.contains(definition.id);
    final tools = service.availableTools
        .where(
          (tool) => tool.name.startsWith(
            '${ConnectorService.toolPrefix}${definition.provider}__',
          ),
        )
        .toList(growable: false);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(
              children: [
                Icon(
                  definition.id == 'github'
                      ? Icons.code_outlined
                      : Icons.cloud_outlined,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        definition.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _statusText(snapshot),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Tooltip(
                  message: '关闭只移除 Agent 工具，不会删除授权',
                  child: Switch(
                    value: snapshot.enabled,
                    onChanged: busy
                        ? null
                        : (enabled) async {
                            await _run(
                              definition.id,
                              () => service.setEnabled(definition.id, enabled),
                              enabled
                                  ? '已启用 ${definition.name} 连接器'
                                  : '已禁用 Agent 工具，授权仍然保留',
                            );
                          },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                definition.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (snapshot.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(
                snapshot.error,
                style: TextStyle(fontSize: 12, color: Colors.red.shade400),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Granted scopes：${snapshot.grantedScopes.isEmpty ? '授权后显示' : snapshot.grantedScopes.join(' · ')}',
                  style: const TextStyle(fontSize: 11),
                ),
                if (snapshot.expiresAt != null)
                  Text(
                    '授权过期时间：${_formatTime(snapshot.expiresAt!)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                const Text(
                  'Agent 权限：只读，不提供远端写入、删除、PR 或 Actions 触发工具',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (!snapshot.configured)
                  const Text(
                    '未配置 OAuth，请检查应用配置',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else if (snapshot.status == ConnectorAuthStatus.authorizing)
                  OutlinedButton.icon(
                    onPressed: () => _cancelAuthorization(definition.id),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('取消授权'),
                  )
                else if (!snapshot.isConnected)
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => _run(
                            definition.id,
                            () => service.connect(definition.id),
                            '${definition.name} 授权成功',
                          ),
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('授权连接'),
                  ),
                if (snapshot.configured)
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _run(
                            definition.id,
                            () => service.refresh(definition.id),
                            '${definition.name} 授权状态已刷新',
                          ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新'),
                  ),
                if (snapshot.configured)
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => _disconnect(definition.id, definition.name),
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text('断开'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ExpansionTile(
            dense: true,
            leading: const Icon(Icons.handyman_outlined, size: 18),
            title: Text(
              '实际暴露给 Agent 的只读工具（${tools.length}）',
              style: const TextStyle(fontSize: 12),
            ),
            children: [
              if (tools.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '启用连接器并完成授权后，工具才会出现在 Agent 工具目录中。',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                )
              else
                for (final tool in tools) _ToolDetail(tool: tool),
            ],
          ),
        ],
      ),
    );
  }

  static String _statusText(ConnectorAuthSnapshot snapshot) {
    final status = switch (snapshot.status) {
      ConnectorAuthStatus.unconfigured => '未配置 OAuth',
      ConnectorAuthStatus.signedOut => '未授权',
      ConnectorAuthStatus.authorizing => '正在授权',
      ConnectorAuthStatus.connected => '已连接',
      ConnectorAuthStatus.error => '授权异常',
    };
    final account = snapshot.accountLabel.isEmpty
        ? ''
        : ' · ${snapshot.accountLabel}';
    final enabled = snapshot.enabled ? '' : ' · Agent 工具已禁用';
    return '$status$account$enabled';
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.tool});

  final McpTool tool;

  @override
  Widget build(BuildContext context) {
    final properties = tool.parameters['properties'];
    final required = (tool.parameters['required'] as List?)?.toSet() ?? {};
    final parameters = <String>[];
    if (properties is Map) {
      for (final entry in properties.entries) {
        final schema = entry.value;
        final type = schema is Map ? '${schema['type'] ?? 'value'}' : 'value';
        final description = schema is Map
            ? '${schema['description'] ?? ''}'
            : '';
        parameters.add(
          '${entry.key}${required.contains(entry.key) ? '（必填）' : '（可选）'}'
          ' · $type${description.isEmpty ? '' : ' · $description'}',
        );
      }
    }
    return ListTile(
      dense: true,
      title: Text(
        tool.name,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
      subtitle: Text(
        '${tool.description}${parameters.isEmpty ? '\n无参数' : '\n${parameters.join('\n')}'}',
        style: const TextStyle(fontSize: 11, height: 1.45),
      ),
    );
  }
}
