import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipe_editor/agent/tool_contract.dart';
import 'package:slipe_editor/models/ai_connector.dart';
import 'package:slipe_editor/services/ai_connector_service.dart';

class FakeConnector implements AiConnector {
  FakeConnector({ConnectorAuthSnapshot? snapshot, this.onExecute})
    : snapshot = snapshot ?? signedOutSnapshot;

  static const signedOutSnapshot = ConnectorAuthSnapshot(
    configured: true,
    enabled: true,
    status: ConnectorAuthStatus.signedOut,
  );

  static const connectedSnapshot = ConnectorAuthSnapshot(
    configured: true,
    enabled: true,
    status: ConnectorAuthStatus.connected,
    accountLabel: 'octocat',
    grantedScopes: ['repo', 'read:user'],
  );

  @override
  final ConnectorDefinition definition = const ConnectorDefinition(
    id: 'fake',
    name: 'Fake',
    description: '测试只读连接器',
    provider: 'fake',
  );

  @override
  ConnectorAuthSnapshot snapshot;

  final Future<String> Function(Map<String, dynamic> args)? onExecute;
  int authorizeCalls = 0;
  int disconnectCalls = 0;
  int refreshCalls = 0;

  @override
  Future<void> authorize() async {
    authorizeCalls++;
    snapshot = connectedSnapshot;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    snapshot = signedOutSnapshot;
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  List<McpTool> tools() => [
    McpTool(
      name: 'connector__fake__read_text_file',
      description: '读取测试文本',
      parameters: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      execute: (args) async {
        final callback = onExecute;
        if (callback != null) return callback(args);
        return '读取：${args['path']}';
      },
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('注册时拒绝重复 id，未授权时不暴露工具', () async {
    final connector = FakeConnector();
    final service = ConnectorService()..register(connector);
    await service.ensureLoaded();

    expect(service.connectors, hasLength(1));
    expect(service.availableTools, isEmpty);
    expect(
      () => service.register(FakeConnector()),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      await service.execute('connector__fake__read_text_file', {'path': 'a'}),
      contains('尚未授权'),
    );
  });

  test('授权、刷新、执行路由和快照均正常', () async {
    final connector = FakeConnector();
    final service = ConnectorService()..register(connector);

    await service.connect('fake');
    await service.refresh('fake');
    final snapshot = service.snapshotFor('fake');

    expect(connector.authorizeCalls, 1);
    expect(connector.refreshCalls, 1);
    expect(snapshot.isConnected, isTrue);
    expect(snapshot.enabled, isTrue);
    expect(snapshot.accountLabel, 'octocat');
    expect(snapshot.grantedScopes, ['repo', 'read:user']);
    expect(service.availableTools, hasLength(1));
    expect(service.isReadOnlyTool('connector__fake__read_text_file'), isTrue);
    expect(
      await service.execute('connector__fake__read_text_file', {
        'path': 'README.md',
      }),
      '读取：README.md',
    );
  });

  test('禁用状态持久化，禁用只移除工具而不断开授权', () async {
    final connector = FakeConnector(snapshot: FakeConnector.connectedSnapshot);
    final service = ConnectorService()..register(connector);
    await service.setEnabled('fake', false);

    expect(service.availableTools, isEmpty);
    expect(service.snapshotFor('fake').isConnected, isTrue);
    expect(service.snapshotFor('fake').enabled, isFalse);
    expect(connector.disconnectCalls, 0);
    expect(
      await service.execute('connector__fake__read_text_file', {'path': 'a'}),
      contains('已禁用'),
    );

    final restoredConnector = FakeConnector(
      snapshot: FakeConnector.connectedSnapshot,
    );
    final restored = ConnectorService()..register(restoredConnector);
    await restored.ensureLoaded();
    expect(restored.isEnabled('fake'), isFalse);
    expect(restored.availableTools, isEmpty);
  });

  test('断开会调用适配器并停止暴露工具', () async {
    final connector = FakeConnector(snapshot: FakeConnector.connectedSnapshot);
    final service = ConnectorService()..register(connector);
    await service.disconnect('fake');

    expect(connector.disconnectCalls, 1);
    expect(service.snapshotFor('fake').isConnected, isFalse);
    expect(service.availableTools, isEmpty);
    expect(
      await service.execute('connector__fake__read_text_file', {'path': 'a'}),
      contains('尚未授权'),
    );
  });

  test('执行异常和展示错误会移除常见令牌', () async {
    final connector = FakeConnector(
      snapshot: FakeConnector.connectedSnapshot,
      onExecute: (_) async => throw StateError(
        'Bearer abc.def?token=url-secret&access_token=other-secret&x=1',
      ),
    );
    final service = ConnectorService()..register(connector);
    final result = await service.execute('connector__fake__read_text_file', {
      'path': 'a',
    });

    expect(result, contains('Bearer [redacted]'));
    expect(result, contains('token=[redacted]'));
    expect(result, isNot(contains('abc.def')));
    expect(result, isNot(contains('url-secret')));
    expect(result, isNot(contains('other-secret')));
    expect(
      ConnectorService.safeError('?access_token=secret&x=1'),
      '?access_token=[redacted]&x=1',
    );
  });

  test('未知工具返回明确错误', () async {
    final service = ConnectorService()..register(FakeConnector());
    expect(
      await service.execute('connector__fake__missing', {}),
      contains('未知'),
    );
  });
}
