import 'package:flutter_test/flutter_test.dart';
import 'package:slipe_editor/models/app_settings.dart';
import 'package:slipe_editor/services/agent_permission_service.dart';

void main() {
  final service = AgentPermissionService.instance;

  AppSettings settings({
    String mode = 'auto',
    String rules = '',
  }) =>
      AppSettings(agentApprovalMode: mode, agentApprovalRules: rules);

  setUp(() {
    service.resetSession();
    service.handler = null;
    service.settingsReader = () => settings();
  });

  tearDown(() {
    service.handler = null;
    service.settingsReader = null;
  });

  test('风险分级：普通命令 vs 高风险命令', () {
    expect(
      AgentPermissionService.riskOf('run_terminal_command', {
        'command': 'npm test',
      }),
      AgentRiskLevel.execute,
    );
    expect(
      AgentPermissionService.riskOf('run_terminal_command', {'command': 'rm -rf build'}),
      AgentRiskLevel.critical,
    );
    expect(
      AgentPermissionService.riskOf('write_file', {'path': 'a.dart'}),
      AgentRiskLevel.write,
    );
    expect(AgentPermissionService.riskOf('read_file', {'path': 'a'}), AgentRiskLevel.safe);
    expect(
      AgentPermissionService.looksCriticalForTest('git push origin main'),
      isTrue,
    );
    expect(
      AgentPermissionService.looksCriticalForTest('git status'),
      isFalse,
    );
  });

  test('自动模式：普通写入放行，高风险操作在无审批界面时拒绝', () async {
    expect(
      await service.check('write_file', {'path': 'lib/a.dart', 'content': 'x'}),
      isNull,
    );
    expect(await service.check('delete_file', {'path': 'lib/a.dart'}), isNotNull);
  });

  test('手动模式会请求审批，拒绝后阻止执行', () async {
    service.settingsReader = () => settings(mode: 'manual');
    AgentPermissionRequest? asked;
    service.handler = (request) async {
      asked = request;
      return false;
    };
    final result = await service.check('write_file', {
      'path': 'lib/a.dart',
      'content': 'x',
    });
    expect(asked?.tool, 'write_file');
    expect(result, isNotNull);
  });

  test('完全访问模式不再询问', () async {
    service.settingsReader = () => settings(mode: 'full');
    var asked = false;
    service.handler = (request) async {
      asked = true;
      return true;
    };
    expect(await service.check('delete_file', {'path': 'x'}), isNull);
    expect(asked, isFalse);
  });

  test('自定义规则可拒绝或放行', () async {
    service.settingsReader = () => settings(
      mode: 'custom',
      rules: 'deny delete_file\nallow run_terminal_command:git status',
    );
    expect(await service.check('delete_file', {'path': 'x'}), isNotNull);
    expect(
      await service.check('run_terminal_command', {'command': 'git status'}),
      isNull,
    );
    // 未命中的命令仍需询问
    var asked = false;
    service.handler = (request) async {
      asked = true;
      return true;
    };
    await service.check('run_terminal_command', {'command': 'npm test'});
    expect(asked, isTrue);
  });
}
