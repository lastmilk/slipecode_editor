import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipe_editor/agent/mcp_tools.dart';
import 'package:slipe_editor/models/ai_connector.dart';
import 'package:slipe_editor/providers/build_provider.dart';
import 'package:slipe_editor/providers/editor_provider.dart';
import 'package:slipe_editor/providers/git_sync_provider.dart';
import 'package:slipe_editor/providers/gitee_provider.dart';
import 'package:slipe_editor/providers/github_provider.dart';
import 'package:slipe_editor/providers/project_provider.dart';
import 'package:slipe_editor/services/ai_connector_service.dart';
import 'package:slipe_editor/services/external_mcp_manager.dart';

class ReadOnlyConnector implements AiConnector {
  @override
  final ConnectorDefinition definition = const ConnectorDefinition(
    id: 'fake',
    name: 'Fake',
    description: '测试只读连接器',
    provider: 'fake',
  );

  @override
  final ConnectorAuthSnapshot snapshot = const ConnectorAuthSnapshot(
    configured: true,
    enabled: true,
    status: ConnectorAuthStatus.connected,
  );

  @override
  Future<void> authorize() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> refresh() async {}

  @override
  List<McpTool> tools() => [
    McpTool(
      name: 'connector__fake__read',
      description: '只读测试工具',
      parameters: const {'type': 'object', 'properties': {}},
      execute: (_) async => 'connector-ok',
    ),
  ];
}

McpToolbox createToolbox(ProjectProvider project, ConnectorService connectors) {
  final github = GitHubProvider();
  final gitee = GiteeProvider();
  final sync = GitSyncProvider(github, gitee, project);
  return McpToolbox(
    project: project,
    editor: EditorProvider(),
    build: BuildProvider(github, gitee, sync, project),
    connectors: connectors,
  );
}

Set<String> definitionNames(List<Map<String, dynamic>> definitions) => {
  for (final definition in definitions)
    (definition['function'] as Map)['name'].toString(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('无项目时只暴露交互、动态和连接器工具', () async {
    final project = ProjectProvider();
    final connectors = ConnectorService()..register(ReadOnlyConnector());
    final toolbox = createToolbox(project, connectors);
    toolbox.setExtraTools([
      McpTool(
        name: 'web_search',
        description: '动态搜索工具',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (_) async => 'dynamic-ok',
      ),
    ]);

    final names = definitionNames(toolbox.definitions);
    expect(
      names,
      containsAll([
        'update_todo_list',
        'ask_user',
        'submit_plan',
        'web_search',
        'connector__fake__read',
      ]),
    );
    expect(names, isNot(contains('get_project_info')));
    expect(names, isNot(contains('read_file')));
    expect(names, isNot(contains('run_build')));

    final planNames = definitionNames(toolbox.definitionsFor(planOnly: true));
    expect(planNames, contains('connector__fake__read'));
    expect(planNames, contains('submit_plan'));
    expect(
      McpToolbox.isWriteTool('${ExternalMcpManager.toolPrefix}anything'),
      isTrue,
    );
  });

  test('无项目执行层同时隔离项目工具，全局工具仍可使用', () async {
    final project = ProjectProvider();
    final connectors = ConnectorService()..register(ReadOnlyConnector());
    final toolbox = createToolbox(project, connectors);
    toolbox.onAskUser = (_, _, _) async => 'chosen';
    toolbox.onSubmitPlan = (_, _) async => true;
    toolbox.onTodoUpdate = (_) {};
    toolbox.setExtraTools([
      McpTool(
        name: 'web_search',
        description: '动态搜索工具',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (_) async => 'dynamic-ok',
      ),
    ]);

    expect(await toolbox.execute('read_file', {'path': 'a'}), contains('挂载项目'));
    expect(await toolbox.execute('get_project_info', {}), contains('挂载项目'));
    expect(await toolbox.execute('web_search', {}), 'dynamic-ok');
    expect(await toolbox.execute('connector__fake__read', {}), 'connector-ok');
    expect(
      await toolbox.execute('ask_user', {'question': '选择？'}),
      '用户回答：chosen',
    );
    expect(
      await toolbox.execute('update_todo_list', {
        'todos': [
          {'content': '验证', 'status': 'completed'},
        ],
      }),
      contains('1/1 完成'),
    );
    expect(
      await toolbox.execute('submit_plan', {'title': '测试', 'markdown': '# 计划'}),
      startsWith('PLAN_CONFIRMED'),
    );
  });

  test('显式挂载项目后恢复项目工具定义与执行', () async {
    final root = await Directory.systemTemp.createTemp('slipe_tool_scope_');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'hello.txt')).writeAsString('hello scope');

    final project = ProjectProvider();
    await project.openProject(root.path);
    final connectors = ConnectorService()..register(ReadOnlyConnector());
    final toolbox = createToolbox(project, connectors);

    final names = definitionNames(toolbox.definitions);
    expect(names, contains('get_project_info'));
    expect(names, contains('read_file'));
    expect(names, contains('connector__fake__read'));
    expect(
      await toolbox.execute('read_file', {'path': 'hello.txt'}),
      contains('hello scope'),
    );
    expect(await toolbox.execute('get_project_info', {}), contains(root.path));
  });
}
