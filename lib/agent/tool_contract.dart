/// MCP 风格工具契约
///
/// 独立成文件，便于桌面工具集（desktop_tools.dart）复用，
/// 避免与 McpToolbox 形成循环依赖。
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  final Future<String> Function(Map<String, dynamic> args) execute;

  const McpTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  /// 转成 OpenAI function-calling 定义
  Map<String, dynamic> toDefinition() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}
