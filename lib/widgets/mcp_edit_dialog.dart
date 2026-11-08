import 'package:flutter/material.dart';

import '../models/mcp_config.dart';
import '../services/ai_extensions_service.dart';
import '../services/external_mcp_manager.dart';

/// MCP 配置编辑对话框返回的草稿数据
typedef McpDraft = ({
  String name,
  String transport,
  String url,
  Map<String, String> headers,
  String command,
  List<String> args,
  Map<String, String> env,
});

/// 弹出 MCP 服务器编辑对话框并保存（新增或编辑）。
///
/// 保存后立即尝试连接，供 AGC 工具面板与设置页共用。
Future<void> showMcpServerEditor(
  BuildContext context, {
  McpServerConfig? existing,
}) async {
  final draft = await showDialog<McpDraft>(
    context: context,
    builder: (_) => McpServerEditDialog(existing: existing),
  );
  if (draft == null) return;
  final service = AiExtensionsService.instance;
  if (existing == null) {
    await service.addServer(
      name: draft.name,
      transport: draft.transport,
      url: draft.url,
      headers: draft.headers,
      command: draft.command,
      args: draft.args,
      env: draft.env,
    );
  } else {
    await service.updateServer(
      existing.copyWith(
        name: draft.name,
        transport: draft.transport,
        url: draft.url,
        headers: draft.headers,
        command: draft.command,
        args: draft.args,
        env: draft.env,
      ),
    );
  }
  // 保存后立即尝试连接，让用户马上看到连接结果
  await ExternalMcpManager.instance.refresh(service.enabledServers);
}

/// 弹出粘贴配置（Claude Desktop / Cursor JSON）导入对话框
Future<void> showMcpConfigImport(BuildContext context) async {
  final controller = TextEditingController();
  final raw = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('粘贴 MCP 配置'),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 8,
          maxLines: 16,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '支持 Claude Desktop / Cursor 格式：\n'
                '{\n'
                '  "mcpServers": {\n'
                '    "filesystem": {\n'
                '      "command": "npx",\n'
                '      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]\n'
                '    },\n'
                '    "remote": {"url": "https://example.com/mcp"}\n'
                '  }\n'
                '}',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('导入'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (raw == null || raw.trim().isEmpty) return;
  final result = await AiExtensionsService.instance.importConfig(raw);
  if (result.imported > 0) {
    await ExternalMcpManager.instance.refresh(
      AiExtensionsService.instance.enabledServers,
    );
  }
  if (!context.mounted) return;
  final message = result.error != null
      ? result.error!
      : '已导入 ${result.imported} 个配置'
          '${result.skipped > 0 ? '，跳过 ${result.skipped} 个' : ''}';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: result.imported > 0 ? Colors.green : Colors.orange,
    ),
  );
}

/// MCP 服务器编辑对话框（添加 / 编辑共用）
class McpServerEditDialog extends StatefulWidget {
  const McpServerEditDialog({super.key, this.existing});

  final McpServerConfig? existing;

  @override
  State<McpServerEditDialog> createState() => _McpServerEditDialogState();
}

class _McpServerEditDialogState extends State<McpServerEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.existing?.url ?? '',
  );
  late final TextEditingController _command = TextEditingController(
    text: widget.existing?.command ?? '',
  );
  late final TextEditingController _args = TextEditingController(
    text: (widget.existing?.args ?? const []).join('\n'),
  );
  late final TextEditingController _headers = TextEditingController(
    text: _formatPairs(widget.existing?.headers ?? const {}, ': '),
  );
  late final TextEditingController _env = TextEditingController(
    text: _formatPairs(widget.existing?.env ?? const {}, '='),
  );
  late String _transport = widget.existing?.transport ?? 'http';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _command.dispose();
    _args.dispose();
    _headers.dispose();
    _env.dispose();
    super.dispose();
  }

  static String _formatPairs(Map<String, String> map, String sep) =>
      map.entries.map((e) => '${e.key}$sep${e.value}').join('\n');

  static Map<String, String> _parsePairs(String raw, String sep) {
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final index = trimmed.indexOf(sep);
      if (index <= 0) continue;
      map[trimmed.substring(0, index).trim()] =
          trimmed.substring(index + sep.length).trim();
    }
    return map;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    final url = _url.text.trim();
    final command = _command.text.trim();
    if (_transport == 'stdio') {
      if (command.isEmpty) {
        setState(() => _error = 'stdio 方式需要填写启动命令');
        return;
      }
    } else if (url.isEmpty) {
      setState(() => _error = '请填写 MCP 服务器地址');
      return;
    }
    Navigator.of(context).pop<McpDraft>((
      name: name,
      transport: _transport,
      url: url,
      headers: _parsePairs(_headers.text, ':'),
      command: command,
      args: _args.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      env: _parsePairs(_env.text, '='),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isStdio = _transport == 'stdio';
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _transport,
                decoration: const InputDecoration(
                  labelText: '传输方式',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'http', child: Text('Streamable HTTP')),
                  DropdownMenuItem(
                      value: 'sse', child: Text('HTTP + SSE（旧版）')),
                  DropdownMenuItem(value: 'stdio', child: Text('stdio（桌面端）')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _transport = value);
                },
              ),
              const SizedBox(height: 12),
              if (isStdio) ...[
                TextField(
                  controller: _command,
                  decoration: const InputDecoration(
                    labelText: '启动命令',
                    hintText: '例如 npx',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _args,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '参数（一行一个）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _env,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '环境变量（每行 KEY=VALUE）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://example.com/mcp',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headers,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '请求头（每行 Key: Value）',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
